Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Invoke-AzureCli {
    param([Parameter(Mandatory)][string[]] $Arguments)
    $output = & az @Arguments --only-show-errors --output json
    if ($LASTEXITCODE -ne 0) {
        throw "Azure CLI failed: az $($Arguments[0..([Math]::Min(2, $Arguments.Length - 1))] -join ' '). See the CLI error above."
    }
    if ($output) {
        return ($output -join "`n" | ConvertFrom-Json -AsHashtable)
    }
}

function Assert-ProjectStoreBindings {
    param(
        [Parameter(Mandatory)][hashtable] $Project,
        [Parameter(Mandatory)][hashtable] $ExpectedStores,
        [object[]] $CapabilityHosts = @(),
        [object[]] $Connections = @()
    )
    $settings = $Project.properties['capabilitySettings']
    if ($settings) {
        foreach ($store in @('blobStore', 'documentStore', 'vectorStore')) {
            if ($settings[$store] -ine $ExpectedStores[$store]) {
                throw "Effective project capability setting does not match the intended resource: $store"
            }
        }
        return 'capabilitySettings'
    }

    Assert-ProjectHostBindings -ExpectedStores $ExpectedStores -CapabilityHosts $CapabilityHosts -Connections $Connections
    return 'capabilityHost'
}

function Assert-ProjectHostBindings {
    param(
        [Parameter(Mandatory)][hashtable] $ExpectedStores,
        [object[]] $CapabilityHosts = @(),
        [object[]] $Connections = @()
    )
    if ($CapabilityHosts.Count -ne 1 -or
        $CapabilityHosts[0].properties['provisioningState'] -ne 'Succeeded' -or
        $CapabilityHosts[0].properties['capabilityHostKind'] -ne 'Agents') {
        throw 'Project has neither effective capability settings nor exactly one healthy Agents capability host.'
    }
    $bindingProperties = @{
        blobStore = 'storageConnections'
        documentStore = 'threadStorageConnections'
        vectorStore = 'vectorStoreConnections'
    }
    $suffixes = @{
        blobStore = '.blob.core.windows.net'
        documentStore = '.documents.azure.com'
        vectorStore = '.search.windows.net'
    }
    foreach ($store in @('blobStore', 'documentStore', 'vectorStore')) {
        $names = @($CapabilityHosts[0].properties[$bindingProperties[$store]])
        if ($names.Count -ne 1 -or [string]::IsNullOrWhiteSpace($names[0])) {
            throw "Project host must bind exactly one $store connection."
        }
        $matching = @($Connections | Where-Object name -eq $names[0])
        $expectedTarget = "https://$($ExpectedStores[$store].Split('/')[-1])$($suffixes[$store])"
        if ($matching.Count -ne 1 -or $matching[0].properties['authType'] -ne 'AAD' -or
            -not $matching[0].properties['metadata'] -or
            $matching[0].properties.metadata['ResourceId'] -ine $ExpectedStores[$store] -or
            ([string] $matching[0].properties['target']).TrimEnd('/') -ine $expectedTarget) {
            throw "Project host $store connection does not match the intended AAD resource."
        }
    }
}

function Get-ProjectRuntimeContainers {
    param(
        [Parameter(Mandatory)][string] $ProjectInternalId,
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]] $Containers
    )
    $workspaceId = [guid]::Empty
    if (-not [guid]::TryParse($ProjectInternalId, [ref] $workspaceId) -or $workspaceId -eq [guid]::Empty) {
        throw 'Project workspace identity is invalid; cannot safely select its backing containers.'
    }
    $prefix = "$($workspaceId.ToString())-"
    $files = @($Containers | Where-Object { $_.name -eq "${prefix}azureml-blobstore" })
    $agents = @($Containers | Where-Object {
        $_.name.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase) -and $_.name -like '*-azureml-agent'
    })
    if ($files.Count -ne 1 -or $agents.Count -ne 1) {
        throw 'Expected exactly one Foundry file container and one agent container for this project. Inspect capability provisioning; do not grant account-wide data-owner access.'
    }
    return @{ Files = $files[0].name; Agents = $agents[0].name }
}

function Get-NetworkRange {
    param([Parameter(Mandatory)][string] $Cidr)
    if ($Cidr -notmatch '^(\d{1,3}(?:\.\d{1,3}){3})/(\d{1,2})$') {
        throw "Invalid IPv4 CIDR: $Cidr"
    }
    $address = $Matches[1]
    $prefix = [int]$Matches[2]
    if ($prefix -gt 32) { throw "Invalid CIDR prefix: $Cidr" }
    $octets = $address.Split('.') | ForEach-Object {
        $number = [int]$_
        if ($number -gt 255) { throw "Invalid IPv4 address: $Cidr" }
        $number
    }
    $ip = [uint64]0
    foreach ($octet in $octets) { $ip = $ip * 256 + $octet }
    $size = [uint64][Math]::Pow(2, 32 - $prefix)
    $start = $ip - ($ip % $size)
    if ($ip -ne $start) { throw "CIDR must start at its network address: $Cidr" }
    return @{ Start = $start; End = $start + $size - 1; Prefix = $prefix; Cidr = $Cidr }
}

function Test-NetworkOverlap {
    param($First, $Second)
    return ($First.Start -le $Second.End -and $Second.Start -le $First.End)
}

function Assert-Configuration {
    param([Parameter(Mandatory)][hashtable] $Config)
    foreach ($key in @('location', 'workloadName', 'nameSuffix', 'projectName', 'resourceNames', 'tags', 'network', 'hub', 'vm', 'services', 'models')) {
        if (-not $Config.ContainsKey($key)) { throw "Missing configuration property: $key" }
    }
    $unexpected = @($Config.Keys | Where-Object {
        $_ -notin @('location', 'workloadName', 'nameSuffix', 'projectName', 'resourceNames', 'tags', 'network', 'hub', 'vm', 'services', 'models')
    })
    if ($unexpected.Count) { throw "Unsupported configuration properties: $($unexpected -join ', ')" }
    foreach ($key in @('workloadName', 'nameSuffix')) {
        if ($Config[$key] -notmatch '^[a-z0-9]{1,6}$') { throw "$key must be 1-6 lowercase letters or digits." }
    }
    if ($Config.location -notmatch '^[a-z0-9]+$') { throw 'Use an Azure region name such as westus3.' }
    if ($Config.projectName -notmatch '^[a-zA-Z0-9][a-zA-Z0-9_.-]{1,63}$') { throw 'Invalid Foundry project name.' }
    $allowedOverrides = @('hubResourceGroup', 'spokeResourceGroup', 'hubVnet', 'spokeVnet', 'bastion', 'firewall',
        'firewallPolicy', 'jumpbox', 'storage', 'cosmos', 'search', 'keyVault', 'foundry', 'logAnalytics', 'appInsights', 'monitorScope')
    foreach ($key in $Config.resourceNames.Keys) {
        if ($key -notin $allowedOverrides -or [string]::IsNullOrWhiteSpace($Config.resourceNames[$key])) {
            throw "Invalid resource name override: $key"
        }
    }
    if ($Config.services.cosmosTotalThroughputLimit -lt 6000) { throw 'Cosmos throughput limit must allow at least 6000 RU/s.' }
    if ($Config.vm.osDiskSizeGB -lt 64) { throw 'Windows OS disk must be at least 64 GB.' }
    if ($Config.services.logDailyQuotaGB -lt 1) { throw 'Log daily quota must be at least 1 GB.' }
    if ($Config.services.logRetentionDays -lt 30 -or $Config.services.logRetentionDays -gt 730) {
        throw 'Log retention must be 30-730 days.'
    }
    if ($Config.hub.firewallSku -notin @('Standard', 'Premium') -or $Config.hub.bastionSku -notin @('Standard', 'Premium')) {
        throw 'Firewall and Bastion require Standard or Premium.'
    }
    foreach ($name in @($Config.network.agentSubnetName, $Config.network.privateEndpointSubnetName)) {
        if ($name -notmatch '^[a-zA-Z0-9][a-zA-Z0-9_.-]{0,62}$') { throw "Invalid subnet name: $name" }
    }
    if ($Config.network.agentSubnetName -eq $Config.network.privateEndpointSubnetName) { throw 'Spoke subnet names must differ.' }
    $hub = Get-NetworkRange $Config.network.hubAddressPrefix
    $spoke = Get-NetworkRange $Config.network.spokeAddressPrefix
    if (Test-NetworkOverlap $hub $spoke) { throw 'Hub and spoke address spaces overlap.' }
    $privateRanges = @('10.0.0.0/8', '172.16.0.0/12', '192.168.0.0/16') | ForEach-Object { Get-NetworkRange $_ }
    $reserved = @('172.30.0.0/16', '172.31.0.0/16', '192.168.0.0/24') | ForEach-Object { Get-NetworkRange $_ }
    foreach ($range in @($hub, $spoke)) {
        $contained = @($privateRanges | Where-Object { $range.Start -ge $_.Start -and $range.End -le $_.End })
        if (-not $contained.Count) { throw "Use RFC1918 address space: $($range.Cidr)" }
        foreach ($blocked in $reserved) {
            if (Test-NetworkOverlap $range $blocked) { throw "Address space overlaps a Foundry-reserved range: $($blocked.Cidr)" }
        }
    }
    $subnets = @(
        @{ Range = (Get-NetworkRange $Config.network.bastionSubnetPrefix); Parent = $hub; MaximumPrefix = 26 },
        @{ Range = (Get-NetworkRange $Config.network.firewallSubnetPrefix); Parent = $hub; MaximumPrefix = 26 },
        @{ Range = (Get-NetworkRange $Config.network.jumpboxSubnetPrefix); Parent = $hub; MaximumPrefix = 27 },
        @{ Range = (Get-NetworkRange $Config.network.agentSubnetPrefix); Parent = $spoke; MaximumPrefix = 27 },
        @{ Range = (Get-NetworkRange $Config.network.privateEndpointSubnetPrefix); Parent = $spoke; MaximumPrefix = 27 }
    )
    foreach ($subnet in $subnets) {
        if ($subnet.Range.Start -lt $subnet.Parent.Start -or $subnet.Range.End -gt $subnet.Parent.End) {
            throw "Subnet is outside its VNet: $($subnet.Range.Cidr)"
        }
        if ($subnet.Range.Prefix -gt $subnet.MaximumPrefix) { throw "Subnet is too small: $($subnet.Range.Cidr)" }
    }
    for ($i = 0; $i -lt $subnets.Count; $i++) {
        for ($j = $i + 1; $j -lt $subnets.Count; $j++) {
            if (Test-NetworkOverlap $subnets[$i].Range $subnets[$j].Range) { throw 'Subnet address spaces overlap.' }
        }
    }
    if (-not $Config.models.Count) { throw 'Configure at least one model deployment.' }
    $deploymentNames = @{}
    foreach ($model in $Config.models) {
        if ($model.deploymentName -notmatch '^[a-zA-Z0-9][a-zA-Z0-9_-]{0,63}$') { throw 'Invalid model deployment name.' }
        if ($deploymentNames.ContainsKey($model.deploymentName)) { throw 'Model deployment names must be unique.' }
        $deploymentNames[$model.deploymentName] = $true
        if ($model.capacity -lt 1 -or $model.sku -notin @('GlobalStandard', 'DataZoneStandard', 'Standard')) {
            throw 'Invalid model deployment capacity or SKU.'
        }
        if ([string]::IsNullOrWhiteSpace($model.version) -or [string]::IsNullOrWhiteSpace($model.modelName)) {
            throw 'Each model needs a name and explicit version.'
        }
    }
    foreach ($fqdn in @($Config.hub.additionalJumpboxFqdns) + @($Config.hub.additionalAgentFqdns)) {
        if ($fqdn -eq '*' -or $fqdn -notmatch '^(\*\.)?[a-zA-Z0-9-]+(\.[a-zA-Z0-9-]+)+$') {
            throw "Specify an approved FQDN, not a blanket wildcard or URL: $fqdn"
        }
    }
}

function Get-Configuration {
    param([string] $Path = (Join-Path $PSScriptRoot '..\infra\config.default.json'))
    $config = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json -AsHashtable
    Assert-Configuration $config
    return $config
}

function Get-InteractiveAzureContext {
    $account = Invoke-AzureCli @('account', 'show')
    if ($account.environmentName -ne 'AzureCloud') { throw 'This template supports Azure public cloud only.' }
    if ($account.user.type -ne 'user') { throw 'Use interactive az login; service principal authentication is not supported by this wrapper.' }
    $user = Invoke-AzureCli @('ad', 'signed-in-user', 'show')
    if ($user.id -notmatch '^[a-fA-F0-9-]{36}$') { throw 'Could not resolve the signed-in user object ID.' }
    return @{ SubscriptionId = $account.id; UserObjectId = $user.id }
}

function Get-StageDeploymentName {
    param([hashtable] $Config, [string] $Stage)
    return "$($Config.workloadName)-$($Config.nameSuffix)-$Stage"
}

function Get-DeploymentNames {
    param([hashtable] $Config, [string] $Stage)
    $deployment = Invoke-AzureCli @('deployment', 'sub', 'show', '--name', (Get-StageDeploymentName $Config $Stage))
    if ($deployment.properties.provisioningState -ne 'Succeeded') {
        throw "The $Stage deployment must have succeeded before continuing."
    }
    return $deployment.properties.outputs.resourceNames.value
}

function Set-PrivateJumpboxDisk {
    param(
        [Parameter(Mandatory)][hashtable] $Names,
        [Parameter(Mandatory)][string] $SubscriptionId
    )
    $vm = Invoke-AzureCli @('vm', 'show', '--resource-group', $Names.hubResourceGroup,
        '--name', $Names.jumpbox, '--subscription', $SubscriptionId)
    if ($vm.provisioningState -ne 'Succeeded') { throw 'The jumpbox must be provisioned before hardening its OS disk.' }
    $diskId = $vm.storageProfile.osDisk.managedDisk.id
    $prefix = "/subscriptions/$SubscriptionId/resourceGroups/$($Names.hubResourceGroup)/providers/Microsoft.Compute/disks/"
    if (-not $diskId.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'The jumpbox OS disk is outside the expected hub resource group.'
    }
    $disk = Invoke-AzureCli @('disk', 'show', '--ids', $diskId, '--subscription', $SubscriptionId)
    if ($disk.networkAccessPolicy -ne 'DenyAll' -or $disk.publicNetworkAccess -ne 'Disabled') {
        $disk = Invoke-AzureCli @('disk', 'update', '--ids', $diskId, '--subscription', $SubscriptionId,
            '--network-access-policy', 'DenyAll', '--public-network-access', 'Disabled')
    }
    if ($disk.networkAccessPolicy -ne 'DenyAll' -or $disk.publicNetworkAccess -ne 'Disabled') {
        throw 'The OS disk update did not disable disk export networking.'
    }
    Write-Host 'Jumpbox OS disk export networking is disabled.'
}
