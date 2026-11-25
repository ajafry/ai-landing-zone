#Requires -Version 7.2
[CmdletBinding()]
param(
    [string] $ConfigurationPath = (Join-Path $PSScriptRoot '..\infra\config.default.json'),
    [switch] $RegisterProviders
)
. (Join-Path $PSScriptRoot 'Common.ps1')

$config = Get-Configuration $ConfigurationPath
$context = Get-InteractiveAzureContext
$permissions = Invoke-AzureCli @('rest', '--method', 'get', '--url',
    "https://management.azure.com/subscriptions/$($context.SubscriptionId)/providers/Microsoft.Authorization/permissions?api-version=2015-07-01")
foreach ($action in @('Microsoft.Resources/subscriptions/resourceGroups/write', 'Microsoft.Resources/deployments/write',
    'Microsoft.Authorization/roleAssignments/write', 'Microsoft.Network/virtualNetworks/write',
    'Microsoft.Compute/virtualMachines/write', 'Microsoft.Compute/disks/write',
    'Microsoft.CognitiveServices/accounts/write')) {
    $allowed = $false
    foreach ($permission in $permissions.value) {
        $granted = @($permission.actions | Where-Object { $action -like $_ }).Count -gt 0
        $excluded = @($permission.notActions | Where-Object { $action -like $_ }).Count -gt 0
        if ($granted -and -not $excluded) { $allowed = $true }
    }
    if (-not $allowed) { throw "Missing subscription-scope deployment permission: $action. Activate your eligible role or contact an administrator." }
}

$providers = @('Microsoft.Network', 'Microsoft.Compute', 'Microsoft.ManagedIdentity', 'Microsoft.CognitiveServices',
    'Microsoft.Storage', 'Microsoft.DocumentDB', 'Microsoft.Search', 'Microsoft.KeyVault', 'Microsoft.Insights',
    'Microsoft.OperationalInsights', 'Microsoft.App', 'Microsoft.ContainerService', 'Microsoft.MachineLearningServices')
foreach ($provider in $providers) {
    if ($RegisterProviders) {
        $null = Invoke-AzureCli @('provider', 'register', '--namespace', $provider, '--wait')
    }
    $state = Invoke-AzureCli @('provider', 'show', '--namespace', $provider)
    if ($state.registrationState -ne 'Registered') { throw "Register $provider first, or rerun Preflight.ps1 -RegisterProviders." }
}

$models = @(Invoke-AzureCli @('cognitiveservices', 'model', 'list', '--location', $config.location))
foreach ($requested in $config.models) {
    $matching = @($models | Where-Object {
        $_.model.name -eq $requested.modelName -and $_.model.version -eq $requested.version
    })
    if (-not $matching.Count) { throw "Model $($requested.modelName) version $($requested.version) is unavailable in $($config.location)." }
    $skus = @($matching | ForEach-Object { $_.model.skus } | Where-Object { $_.name -eq $requested.sku })
    if (-not $skus.Count) { throw "SKU $($requested.sku) is unavailable for $($requested.modelName) in $($config.location)." }
    foreach ($sku in $skus) {
        if ($sku['capacity'] -and $sku.capacity['minimum'] -and $requested.capacity -lt $sku.capacity.minimum) {
            throw "Capacity for $($requested.modelName) is below SKU minimum $($sku.capacity.minimum)."
        }
    }
}
$usage = @(Invoke-AzureCli @('cognitiveservices', 'usage', 'list', '--location', $config.location))
Write-Host 'Model quota (capacity units differ by model; confirm quota before applying the foundry stage):'
$usage | Where-Object { $_.name.value -like '*OpenAI*' } |
    ForEach-Object { [pscustomobject]@{ Quota = $_.name.value; Used = $_.currentValue; Limit = $_.limit } } |
    Format-Table -AutoSize

$skus = @(Invoke-AzureCli @('vm', 'list-skus', '--location', $config.location, '--size', $config.vm.size, '--all'))
$vmSku = @($skus | Where-Object { $_.resourceType -eq 'virtualMachines' -and $_.name -eq $config.vm.size })
if (-not $vmSku.Count -or @($vmSku | ForEach-Object { $_.restrictions } | Where-Object { $_.type -eq 'Location' }).Count) {
    throw "VM SKU $($config.vm.size) is unavailable to this subscription in $($config.location)."
}
if ($config.vm.securityType -eq 'TrustedLaunch') {
    $disabled = @($vmSku | ForEach-Object { $_.capabilities } | Where-Object { $_.name -eq 'TrustedLaunchDisabled' -and $_.value -eq 'True' })
    if ($disabled.Count) { throw 'The selected VM SKU does not support Trusted Launch.' }
}
$image = Invoke-AzureCli @('vm', 'image', 'show', '--location', $config.location, '--urn',
    "$($config.vm.imagePublisher):$($config.vm.imageOffer):$($config.vm.imageSku):$($config.vm.imageVersion)")
if ($image.hyperVGeneration -ne 'V2') { throw 'Use a Generation 2 image for Windows 11.' }
Write-Host 'Preflight completed. Review model and VM-family quotas, Agent Service regional support, Windows licensing, and Azure Policy before deployment.'
