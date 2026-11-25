#Requires -Version 7.2
. (Join-Path $PSScriptRoot '..\scripts\Common.ps1')

function Assert-True {
    param([bool] $Condition, [string] $Message)
    if (-not $Condition) { throw $Message }
}
function Assert-Rejected {
    param([hashtable] $Config, [string] $ExpectedMessage)
    try { Assert-Configuration $Config }
    catch {
        if ($_.Exception.Message -notlike "*$ExpectedMessage*") { throw }
        return
    }
    throw "Expected configuration rejection: $ExpectedMessage"
}
function Get-TemplateResources {
    param([hashtable] $Template)
    $entries = if ($Template.resources -is [System.Collections.IDictionary]) { $Template.resources.Values } else { $Template.resources }
    foreach ($resource in $entries) {
        if ($resource['existing']) { continue }
        $resource
        if ($resource.type -eq 'Microsoft.Resources/deployments' -and $resource.properties.template) {
            Get-TemplateResources $resource.properties.template
        }
    }
}

$defaultPath = Join-Path $PSScriptRoot '..\infra\config.default.json'
$config = Get-Configuration $defaultPath
$copy = Get-Content $defaultPath -Raw | ConvertFrom-Json -AsHashtable
$copy.network.spokeAddressPrefix = $copy.network.hubAddressPrefix
Assert-Rejected $copy 'overlap'
$copy = Get-Content $defaultPath -Raw | ConvertFrom-Json -AsHashtable
$copy.network.agentSubnetPrefix = '10.20.0.0/28'
Assert-Rejected $copy 'too small'
$copy = Get-Content $defaultPath -Raw | ConvertFrom-Json -AsHashtable
$copy.network.firewallSubnetPrefix = '10.10.0.0/26'
Assert-Rejected $copy 'overlap'
$copy = Get-Content $defaultPath -Raw | ConvertFrom-Json -AsHashtable
$copy.hub.additionalAgentFqdns = @('*')
Assert-Rejected $copy 'blanket wildcard'
$copy = Get-Content $defaultPath -Raw | ConvertFrom-Json -AsHashtable
$copy.network.hubAddressPrefix = '172.30.0.0/16'
Assert-Rejected $copy 'reserved'
$copy = Get-Content $defaultPath -Raw | ConvertFrom-Json -AsHashtable
$copy.models[1].deploymentName = $copy.models[0].deploymentName
Assert-Rejected $copy 'unique'

$template = Invoke-AzureCli @('bicep', 'build', '--file', (Join-Path $PSScriptRoot '..\infra\main.bicep'), '--stdout')
$resources = @(Get-TemplateResources $template)
Assert-True ($template.parameters.adminPassword.type -eq 'secureString') 'Bootstrap password must be secure.'
$defaultValue = $template.parameters.config.defaultValue
if ($defaultValue -is [string] -and $defaultValue -match "^\[variables\('([^']+)'\)\]$") {
    $defaultValue = $template.variables[$Matches[1]]
}
Assert-True ($defaultValue.models.Count -eq 2) 'Expected two default model deployments.'
Assert-True ($config.models.modelName -contains 'gpt-5-nano' -and $config.models.modelName -contains 'text-embedding-3-large') 'Required models missing.'
foreach ($type in @('Microsoft.CognitiveServices/accounts', 'Microsoft.Storage/storageAccounts',
    'Microsoft.DocumentDB/databaseAccounts', 'Microsoft.Search/searchServices', 'Microsoft.KeyVault/vaults')) {
    $matching = @($resources | Where-Object { $_.type -eq $type })
    Assert-True ($matching.Count -gt 0) "No deployed resource of type $type."
    foreach ($resource in $matching) {
        Assert-True ($resource.properties.publicNetworkAccess -ieq 'Disabled') "$type allows public access."
    }
}
$monitorResources = @($resources | Where-Object { $_.type -in @('Microsoft.OperationalInsights/workspaces', 'Microsoft.Insights/components') })
foreach ($resource in $monitorResources) {
    Assert-True ($resource.properties.publicNetworkAccessForIngestion -eq 'Disabled') 'Public monitoring ingestion enabled.'
    Assert-True ($resource.properties.publicNetworkAccessForQuery -eq 'Disabled') 'Public monitoring query enabled.'
}
$publicIps = @($resources | Where-Object { $_.type -eq 'Microsoft.Network/publicIPAddresses' })
Assert-True ($publicIps.Count -eq 2) 'Only Bastion and outbound Firewall should have public IPs.'
Assert-True (@($resources | Where-Object { $_.type -eq 'Microsoft.Network/privateEndpoints' }).Count -eq 6) 'All six workload private endpoints must exist.'
$nics = @($resources | Where-Object { $_.type -eq 'Microsoft.Network/networkInterfaces' })
foreach ($nic in $nics) {
    foreach ($ip in $nic.properties.ipConfigurations) {
        Assert-True (-not $ip.properties.ContainsKey('publicIPAddress')) 'Jumpbox must not have a public IP.'
    }
}
$bastionNsg = @($resources | Where-Object {
    $_.type -eq 'Microsoft.Network/networkSecurityGroups' -and
    $_.properties.securityRules.name -contains 'HttpsFromInternet'
})[0]
$bastionTargets = @($bastionNsg.properties.securityRules | Where-Object {
    $_.properties.direction -eq 'Outbound' -and $_.properties.access -eq 'Allow' -and
    $_.properties.destinationAddressPrefix -eq 'VirtualNetwork' -and
    $_.properties.ContainsKey('destinationPortRanges') -and
    $_.properties.destinationPortRanges -contains '22' -and
    $_.properties.destinationPortRanges -contains '3389' -and
    $_.properties.protocol -in @('Tcp', '*')
})
Assert-True ($bastionTargets.Count -eq 1) 'Bastion requires private SSH and RDP egress to the VirtualNetwork service tag.'
$loginExtension = @($resources | Where-Object {
    $_.type -eq 'Microsoft.Compute/virtualMachines/extensions' -and
    $_.properties.type -eq 'AADLoginForWindows'
})[0]
Assert-True ($loginExtension.properties['enableAutomaticUpgrade'] -ne $true) 'AADLoginForWindows does not support automatic extension upgrade.'
$scope = @($resources | Where-Object { $_.type -eq 'Microsoft.Insights/privateLinkScopes' })[0]
Assert-True ($scope.properties.accessModeSettings.queryAccessMode -eq 'PrivateOnly') 'AMPLS query must be private-only.'
Assert-True ($scope.properties.accessModeSettings.ingestionAccessMode -eq 'PrivateOnly') 'AMPLS ingestion must be private-only.'
$account = @($resources | Where-Object { $_.type -eq 'Microsoft.CognitiveServices/accounts' })[0]
Assert-True ($account.apiVersion -eq '2026-07-15-preview') 'Capability-settings API contract changed.'
Assert-True ($account.properties.capabilitySettings.Keys.Count -eq 3) 'All three BYO stores must be bound.'
Assert-True ($account.properties.networkInjections[0].scenario -eq 'agent') 'Agent injection missing.'
Assert-True ($account.properties.networkAcls.bypass -eq 'None') 'Foundry must not allow trusted-service bypass.'
Assert-True ($account.properties.disableLocalAuth -eq $true) 'Foundry key authentication enabled.'
foreach ($resource in @($resources | Where-Object { $_.type -in @('Microsoft.DocumentDB/databaseAccounts', 'Microsoft.Search/searchServices') })) {
    Assert-True ($resource.properties.disableLocalAuth -eq $true) 'Dependent services must disable local-key authentication.'
}
$storage = @($resources | Where-Object { $_.type -eq 'Microsoft.Storage/storageAccounts' })[0]
Assert-True ($storage.properties.allowSharedKeyAccess -eq $false -and $storage.properties.allowBlobPublicAccess -eq $false) 'Storage must reject shared keys and anonymous Blob access.'
Assert-True (@($resources | Where-Object { $_.type -like '*capabilityHosts' }).Count -eq 0) 'Do not mix legacy capability hosts and current capability settings.'
$dnsTemplate = @($resources | Where-Object { $_.name -eq 'shared-private-dns' })[0].properties.template
Assert-True (@((Get-TemplateResources $dnsTemplate) | Where-Object { $_.type -eq 'Microsoft.Network/privateDnsZones/virtualNetworkLinks' }).Count -eq 2) 'DNS zones must link to both VNets.'
$runtimeTemplate = @($resources | Where-Object { $_.name -eq 'project-runtime-access' })[0].properties.template
$owner = @((Get-TemplateResources $runtimeTemplate) | Where-Object { $_.name -like '*agent-data-owner*' })
Assert-True ($owner.Count -eq 1 -and $owner[0].scope -like '*blobServices*containers*') 'Agent blob owner role must be container-scoped.'
foreach ($script in Get-ChildItem -LiteralPath (Join-Path $PSScriptRoot '..\scripts') -Filter '*.ps1') {
    $tokens = $null
    $errors = $null
    $null = [Management.Automation.Language.Parser]::ParseFile($script.FullName, [ref]$tokens, [ref]$errors)
    Assert-True ($errors.Count -eq 0) "PowerShell parse failure: $($script.Name): $errors"
}
$readme = Get-Content -LiteralPath (Join-Path $PSScriptRoot '..\README.md') -Raw
foreach ($block in [regex]::Matches($readme, '(?ms)^```powershell\r?\n(.*?)^```')) {
    $tokens = $null
    $errors = $null
    $null = [Management.Automation.Language.Parser]::ParseInput($block.Groups[1].Value, [ref]$tokens, [ref]$errors)
    Assert-True ($errors.Count -eq 0) "Documentation command syntax error: $errors"
}

if ($IsWindows) {
    $global:LandingZoneTestState = @{
        UserId = [guid]::NewGuid().ToString()
        SubscriptionId = [guid]::NewGuid().ToString()
        ParameterPath = $null
        SawWhatIf = $false
        ModelMinimumCapacity = 1
        DiskPrivate = $false
        DiskUpdateCalls = 0
        RejectDiskUpdate = $false
        DeniedAction = $null
    }
    function az {
        $cliArguments = @($args)
        $global:LASTEXITCODE = 0
        if ($cliArguments[0] -eq 'account' -and $cliArguments[1] -eq 'show') {
            return (@{ environmentName = 'AzureCloud'; id = $global:LandingZoneTestState.SubscriptionId; user = @{ type = 'user' } } | ConvertTo-Json)
        }
        if ($cliArguments[0] -eq 'ad' -and $cliArguments[1] -eq 'signed-in-user') {
            return (@{ id = $global:LandingZoneTestState.UserId } | ConvertTo-Json)
        }
        if ($cliArguments[0] -eq 'rest') {
            $excluded = if ($global:LandingZoneTestState.DeniedAction) { @($global:LandingZoneTestState.DeniedAction) } else { @() }
            return (@{ value = @(@{ actions = @('*'); notActions = @($excluded) }) } | ConvertTo-Json -Depth 10)
        }
        if ($cliArguments[0] -eq 'provider' -and $cliArguments[1] -eq 'show') {
            return '{"registrationState":"Registered"}'
        }
        if ($cliArguments[0] -eq 'cognitiveservices' -and $cliArguments[1] -eq 'model') {
            $models = @(Get-Configuration $defaultPath).models | ForEach-Object {
                @{
                    kind = 'AIServices'
                    model = @{
                        name = $_.modelName
                        version = $_.version
                        skus = @(@{
                            name = $_.sku
                            capacity = @{ minimum = $global:LandingZoneTestState.ModelMinimumCapacity }
                        })
                    }
                }
            }
            return (ConvertTo-Json -InputObject @($models) -Depth 10)
        }
        if ($cliArguments[0] -eq 'cognitiveservices' -and $cliArguments[1] -eq 'usage') {
            return '[]'
        }
        if ($cliArguments[0] -eq 'vm' -and $cliArguments[1] -eq 'list-skus') {
            return (@(@{
                name = (Get-Configuration $defaultPath).vm.size
                resourceType = 'virtualMachines'
                restrictions = @()
                capabilities = @()
            }) | ConvertTo-Json -AsArray -Depth 10)
        }
        if ($cliArguments[0] -eq 'vm' -and $cliArguments[1] -eq 'image') {
            return '{"hyperVGeneration":"V2"}'
        }
        if ($cliArguments[0] -eq 'vm' -and $cliArguments[1] -eq 'show') {
            return (@{
                provisioningState = 'Succeeded'
                storageProfile = @{
                    osDisk = @{
                        managedDisk = @{
                            id = "/subscriptions/$($global:LandingZoneTestState.SubscriptionId)/resourceGroups/rg-test-hub/providers/Microsoft.Compute/disks/os-test"
                        }
                    }
                }
            } | ConvertTo-Json -Depth 10)
        }
        if ($cliArguments[0] -eq 'disk') {
            if ($cliArguments[1] -eq 'update') {
                $global:LandingZoneTestState.DiskUpdateCalls++
                $subscriptionIndex = [Array]::IndexOf($cliArguments, '--subscription')
                Assert-True ($subscriptionIndex -ge 0 -and
                    $cliArguments[$subscriptionIndex + 1] -eq $global:LandingZoneTestState.SubscriptionId) 'Disk update must target the resolved subscription.'
                $networkIndex = [Array]::IndexOf($cliArguments, '--network-access-policy')
                $publicIndex = [Array]::IndexOf($cliArguments, '--public-network-access')
                Assert-True ($networkIndex -ge 0 -and $cliArguments[$networkIndex + 1] -eq 'DenyAll' -and
                    $publicIndex -ge 0 -and $cliArguments[$publicIndex + 1] -eq 'Disabled') 'Disk update must close both export networking settings.'
                if (-not $global:LandingZoneTestState.RejectDiskUpdate) { $global:LandingZoneTestState.DiskPrivate = $true }
            } elseif ($cliArguments[1] -ne 'show') {
                throw 'Unexpected disk operation.'
            }
            return (@{
                networkAccessPolicy = $(if ($global:LandingZoneTestState.DiskPrivate) { 'DenyAll' } else { 'AllowAll' })
                publicNetworkAccess = $(if ($global:LandingZoneTestState.DiskPrivate) { 'Disabled' } else { 'Enabled' })
            } | ConvertTo-Json)
        }
        if ($cliArguments[0] -eq 'deployment' -and $cliArguments[1] -eq 'sub' -and $cliArguments[2] -eq 'what-if') {
            $global:LandingZoneTestState.SawWhatIf = $true
            Assert-True ($cliArguments -contains '--no-pretty-print') 'What-if must return JSON rather than formatted console output.'
            $subscriptionIndex = [Array]::IndexOf($cliArguments, '--subscription')
            Assert-True ($subscriptionIndex -ge 0 -and
                $cliArguments[$subscriptionIndex + 1] -eq $global:LandingZoneTestState.SubscriptionId) 'Deployment must target the subscription resolved at startup.'
            $parameterIndex = [Array]::IndexOf($cliArguments, '--parameters')
            $global:LandingZoneTestState.ParameterPath = $cliArguments[$parameterIndex + 1].Substring(1)
            $document = Get-Content -LiteralPath $global:LandingZoneTestState.ParameterPath -Raw | ConvertFrom-Json -AsHashtable
            Assert-True ($document.parameters.adminPassword.value -eq 'Offline-Test!12345') 'Secure hub password was not passed correctly.'
            $acl = Get-Acl -LiteralPath $global:LandingZoneTestState.ParameterPath
            Assert-True ($acl.AreAccessRulesProtected -and @($acl.Access).Count -eq 1) 'Temporary parameters must have a current-user-only ACL.'
            return '{"changes":[]}'
        }
        throw "Unexpected Azure operation in offline test: $($cliArguments -join ' ')"
    }
    try {
        $securePassword = ConvertTo-SecureString 'Offline-Test!12345' -AsPlainText -Force
        $null = & (Join-Path $PSScriptRoot '..\scripts\Deploy.ps1') -Stage hub -ConfigurationPath $defaultPath -AdminPassword $securePassword
        Assert-True $global:LandingZoneTestState.SawWhatIf 'Deployment wrapper must default to what-if, never apply.'
        Assert-True (-not (Test-Path -LiteralPath $global:LandingZoneTestState.ParameterPath)) 'Temporary secret file was not cleaned up.'
        $diskNames = @{ hubResourceGroup = 'rg-test-hub'; jumpbox = 'vm-test' }
        Set-PrivateJumpboxDisk -Names $diskNames -SubscriptionId $global:LandingZoneTestState.SubscriptionId
        Set-PrivateJumpboxDisk -Names $diskNames -SubscriptionId $global:LandingZoneTestState.SubscriptionId
        Assert-True ($global:LandingZoneTestState.DiskUpdateCalls -eq 1) 'Private disk hardening must not repeat an already applied update.'
        $global:LandingZoneTestState.DiskPrivate = $false
        $global:LandingZoneTestState.RejectDiskUpdate = $true
        $rejected = $false
        try {
            Set-PrivateJumpboxDisk -Names $diskNames -SubscriptionId $global:LandingZoneTestState.SubscriptionId
        } catch {
            if ($_.Exception.Message -notlike '*did not disable*') { throw }
            $rejected = $true
        }
        Assert-True $rejected 'Disk hardening must fail if Azure does not enforce the requested settings.'
        $null = & (Join-Path $PSScriptRoot '..\scripts\Preflight.ps1') -ConfigurationPath $defaultPath
        $global:LandingZoneTestState.DeniedAction = 'Microsoft.Compute/disks/write'
        $rejected = $false
        try {
            $null = & (Join-Path $PSScriptRoot '..\scripts\Preflight.ps1') -ConfigurationPath $defaultPath
        } catch {
            if ($_.Exception.Message -notlike '*Missing subscription-scope deployment permission: Microsoft.Compute/disks/write*') { throw }
            $rejected = $true
        }
        Assert-True $rejected 'Preflight must require OS disk hardening permission before provisioning.'
        $global:LandingZoneTestState.DeniedAction = $null
        $global:LandingZoneTestState.ModelMinimumCapacity = 11
        $rejected = $false
        try {
            $null = & (Join-Path $PSScriptRoot '..\scripts\Preflight.ps1') -ConfigurationPath $defaultPath
        } catch {
            if ($_.Exception.Message -notlike '*below SKU minimum*') { throw }
            $rejected = $true
        }
        Assert-True $rejected 'Preflight must enforce capacity limits from nested model SKU metadata.'
    } finally {
        Remove-Item Function:\az
        Remove-Variable LandingZoneTestState -Scope Global
    }
}
Write-Host 'Offline infrastructure and configuration checks passed.'
