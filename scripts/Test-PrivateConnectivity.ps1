#Requires -Version 7.2
[CmdletBinding()]
param(
    [string] $ConfigurationPath = (Join-Path $PSScriptRoot '..\infra\config.default.json'),
    [switch] $FoundationOnly
)
. (Join-Path $PSScriptRoot 'Common.ps1')

$config = Get-Configuration $ConfigurationPath
$stage = if ($FoundationOnly) { 'foundation' } else { 'access' }
$names = Get-DeploymentNames $config $stage
$context = Get-InteractiveAzureContext
$endpoints = @(Invoke-AzureCli @('network', 'private-endpoint', 'list', '--resource-group', $names.spokeResourceGroup))
$expectedCount = if ($FoundationOnly) { 5 } else { 6 }
if ($endpoints.Count -ne $expectedCount) { throw "Expected $expectedCount private endpoints; found $($endpoints.Count)." }
$privateIps = @()
foreach ($endpoint in $endpoints) {
    foreach ($connection in $endpoint.privateLinkServiceConnections) {
        if ($connection.privateLinkServiceConnectionState.status -ne 'Approved') {
            throw "Private endpoint is not approved: $($endpoint.name)"
        }
    }
    foreach ($interface in $endpoint.networkInterfaces) {
        $nic = Invoke-AzureCli @('network', 'nic', 'show', '--ids', $interface.id)
        $privateIps += @($nic.ipConfigurations | ForEach-Object { $_.privateIPAddress })
    }
}
$hosts = @(
    "$($names.storage).blob.core.windows.net",
    "$($names.cosmos).documents.azure.com",
    "$($names.cosmos)-$($config.location).documents.azure.com",
    "$($names.search).search.windows.net",
    "$($names.keyVault).vault.azure.net",
    'api.loganalytics.io'
)
if (-not $FoundationOnly) {
    $hosts += @("$($names.foundry).services.ai.azure.com", "$($names.foundry).openai.azure.com")
}
foreach ($hostname in $hosts) {
    $addresses = @([Net.Dns]::GetHostAddresses($hostname) |
        Where-Object { $_.AddressFamily -eq [Net.Sockets.AddressFamily]::InterNetwork } |
        ForEach-Object { $_.IPAddressToString })
    if (-not $addresses.Count -or @($addresses | Where-Object { $_ -notin $privateIps }).Count) {
        throw "$hostname does not resolve exclusively to this deployment's private endpoint IPs. Run from the jumpbox and check private DNS links."
    }
    foreach ($address in $addresses) {
        $client = [Net.Sockets.TcpClient]::new()
        try {
            $task = $client.ConnectAsync($address, 443)
            if (-not $task.Wait(10000)) { throw "HTTPS connection timed out: $hostname ($address)" }
            $task.GetAwaiter().GetResult()
        } finally { $client.Dispose() }
    }
    Write-Host "$hostname resolves privately and accepts TCP/443."
}

$resources = @(
    @{ Type = 'Microsoft.Storage/storageAccounts'; Name = $names.storage; Api = '2023-05-01' },
    @{ Type = 'Microsoft.DocumentDB/databaseAccounts'; Name = $names.cosmos; Api = '2024-05-15' },
    @{ Type = 'Microsoft.Search/searchServices'; Name = $names.search; Api = '2025-05-01' },
    @{ Type = 'Microsoft.KeyVault/vaults'; Name = $names.keyVault; Api = '2023-07-01' }
)
if (-not $FoundationOnly) {
    $resources += @{ Type = 'Microsoft.CognitiveServices/accounts'; Name = $names.foundry; Api = '2026-07-15-preview' }
}
foreach ($resource in $resources) {
    $url = "https://management.azure.com/subscriptions/$($context.SubscriptionId)/resourceGroups/$($names.spokeResourceGroup)/providers/$($resource.Type)/$($resource.Name)?api-version=$($resource.Api)"
    $details = Invoke-AzureCli @('rest', '--method', 'get', '--url', $url)
    if ($details.properties.publicNetworkAccess -ine 'Disabled') { throw "Public network access is not disabled: $($resource.Name)" }
}
if (-not $FoundationOnly) {
    $projectUrl = "https://management.azure.com/subscriptions/$($context.SubscriptionId)/resourceGroups/$($names.spokeResourceGroup)/providers/Microsoft.CognitiveServices/accounts/$($names.foundry)/projects/$($config.projectName)?api-version=2026-07-15-preview"
    $project = Invoke-AzureCli @('rest', '--method', 'get', '--url', $projectUrl)
    $hostBindings = @()
    $connections = @()
    if (-not $project.properties['capabilitySettings']) {
        $projectBase = $projectUrl.Split('?')[0]
        $hostBindings = @((Invoke-AzureCli @('rest', '--method', 'get', '--url', "$projectBase/capabilityHosts?api-version=2025-06-01")).value)
        $connections = @((Invoke-AzureCli @('rest', '--method', 'get', '--url', "$projectBase/connections?api-version=2025-06-01")).value)
    }
    $root = "/subscriptions/$($context.SubscriptionId)/resourceGroups/$($names.spokeResourceGroup)/providers"
    $bindingMode = Assert-ProjectStoreBindings -Project $project -CapabilityHosts $hostBindings -Connections $connections -ExpectedStores @{
        blobStore = "$root/Microsoft.Storage/storageAccounts/$($names.storage)"
        documentStore = "$root/Microsoft.DocumentDB/databaseAccounts/$($names.cosmos)"
        vectorStore = "$root/Microsoft.Search/searchServices/$($names.search)"
    }
    Write-Host "Project private stores verified through $bindingMode."
    Write-Host 'Private network checks passed. Run the authenticated model and Agent Service smoke tests in README.md to verify runtime RBAC and agent data access.'
}
