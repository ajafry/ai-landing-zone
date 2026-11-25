#Requires -Version 7.2
[CmdletBinding()]
param(
    [string] $ConfigurationPath = (Join-Path $PSScriptRoot '..\infra\config.default.json'),
    [switch] $Apply
)
. (Join-Path $PSScriptRoot 'Common.ps1')

function Get-ResourceCollection {
    param([Parameter(Mandatory)][string] $Url)
    do {
        $page = Invoke-AzureCli @('rest', '--method', 'get', '--url', $Url)
        if (-not $page.ContainsKey('value') -or $null -eq $page.value) { throw 'Azure returned an invalid resource collection.' }
        foreach ($resource in $page.value) { $resource }
        $Url = $page['nextLink']
        if ($Url -and ([uri] $Url).GetLeftPart([UriPartial]::Authority) -ne 'https://management.azure.com') {
            throw 'Azure returned a resource continuation outside the expected management endpoint.'
        }
    } while ($Url)
}

function Get-BackingStoreState {
    $workspaceId = [guid]::Empty
    if (-not [guid]::TryParse($project.properties.internalId, [ref] $workspaceId) -or $workspaceId -eq [guid]::Empty) {
        throw 'Project workspace identity is invalid; cannot verify backing stores.'
    }
    $prefix = "$workspaceId-"
    $blobs = @(Get-ResourceCollection "$management$($stores.blobStore)/blobServices/default/containers?api-version=2023-05-01")
    $ownedBlobs = @($blobs | Where-Object { $_.name.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase) })
    $blobReady = $false
    if ($ownedBlobs.Count -ge 2) {
        $null = Get-ProjectRuntimeContainers -ProjectInternalId $project.properties.internalId -Containers $ownedBlobs
        $blobReady = $true
    }
    $databases = @(Get-ResourceCollection "$management$($stores.documentStore)/sqlDatabases?api-version=2024-05-15")
    $cosmosContainers = @()
    if (@($databases | Where-Object name -eq 'enterprise_memory').Count -eq 1) {
        $cosmosContainers = @(Get-ResourceCollection "$management$($stores.documentStore)/sqlDatabases/enterprise_memory/containers?api-version=2024-05-15")
    }
    $ownedCosmos = @($cosmosContainers | Where-Object { $_.name.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase) })
    $cosmosNames = @($ownedCosmos | ForEach-Object name)
    $missingCosmos = @('thread-message-store', 'system-thread-message-store', 'agent-entity-store' |
        Where-Object { "$prefix$_" -notin $cosmosNames })
    return @{
        Ready = ($blobReady -and $missingCosmos.Count -eq 0)
        HasProjectData = ($ownedBlobs.Count -gt 0 -or $ownedCosmos.Count -gt 0)
    }
}

function Invoke-ProvisioningTemplate {
    param([string] $Part, [string] $Verb)
    $arguments = @('deployment', 'group', $Verb, '--resource-group', $names.spokeResourceGroup,
        '--subscription', $context.SubscriptionId, '--name', "$(Get-StageDeploymentName $config 'provisioning')-$Part",
        '--mode', 'Incremental', '--template-file', $templates[$Part], '--parameters')
    foreach ($key in $templateParameters[$Part].Keys) { $arguments += "$key=$($templateParameters[$Part][$key])" }
    if ($Verb -eq 'what-if') { $arguments += '--no-pretty-print' }
    $result = Invoke-AzureCli $arguments
    if ($Verb -eq 'create') {
        if ($result.properties.provisioningState -ne 'Succeeded') { throw "Project provisioning $Part deployment did not succeed. Inspect it before retrying." }
    } else {
        if ($result.status -ne 'Succeeded') { throw "Project provisioning $Part preview did not succeed." }
        foreach ($change in $result.changes) {
            if ($change.changeType -in @('Ignore', 'NoChange')) { continue }
            if ($change.changeType -ne 'Create') { throw "Provisioning refuses $($change.changeType); existing resources must not be overwritten." }
            if ($Part -eq 'host') {
                if ($change.resourceId -ine "$projectId/capabilityHosts/agents") { throw 'Host preview includes an unexpected resource.' }
                # What-if has no live provisioning state; validate its planned kind and store bindings.
                $plannedProperties = @{} + $change.after.properties
                $plannedProperties.provisioningState = 'Succeeded'
                Assert-ProjectHostBindings -ExpectedStores $stores -Connections $connections -CapabilityHosts @(@{
                    properties = $plannedProperties
                })
            } else {
                $matching = @($roleScopes.Keys | Where-Object {
                    $change.resourceId -like "$_/providers/Microsoft.Authorization/roleAssignments/*" -and
                    $change.after.properties.roleDefinitionId -ieq $roleScopes[$_]
                })
                if ($matching.Count -ne 1 -or $change.after.properties.principalId -ine $principalId -or
                    $change.after.properties.principalType -ne 'ServicePrincipal') {
                    throw 'Provisioning preview includes an unexpected permission or principal.'
                }
            }
        }
    }
    return $result
}

$config = Get-Configuration $ConfigurationPath
$context = Get-InteractiveAzureContext
$names = Get-DeploymentNames $config 'foundry'
$management = 'https://management.azure.com'
$root = "/subscriptions/$($context.SubscriptionId)/resourceGroups/$($names.spokeResourceGroup)/providers"
$accountId = "$root/Microsoft.CognitiveServices/accounts/$($names.foundry)"
$projectId = "$accountId/projects/$($config.projectName)"
$stores = @{
    blobStore = "$root/Microsoft.Storage/storageAccounts/$($names.storage)"
    documentStore = "$root/Microsoft.DocumentDB/databaseAccounts/$($names.cosmos)"
    vectorStore = "$root/Microsoft.Search/searchServices/$($names.search)"
}
$account = Invoke-AzureCli @('rest', '--method', 'get', '--url', "$management${accountId}?api-version=2026-07-15-preview")
$projectUrl = "$management${projectId}?api-version=2026-07-15-preview"
$project = Invoke-AzureCli @('rest', '--method', 'get', '--url', $projectUrl)
$principalId = $project.identity.principalId
if ($account.properties.provisioningState -ne 'Succeeded' -or $project.properties.provisioningState -ne 'Succeeded' -or
    $principalId -notmatch '^[a-fA-F0-9-]{36}$') { throw 'Foundry account/project and project identity must be successfully provisioned first.' }
if ($account.properties.publicNetworkAccess -ne 'Disabled') { throw 'Foundry public access must remain disabled.' }
$hostsUrl = "$management$projectId/capabilityHosts?api-version=2025-06-01"
$hosts = @(Get-ResourceCollection $hostsUrl)
$connections = @(Get-ResourceCollection "$management$projectId/connections?api-version=2025-06-01")
$configured = ($null -ne $project.properties['capabilitySettings'] -or $hosts.Count -gt 0)
if ($hosts.Count) { Assert-ProjectHostBindings -ExpectedStores $stores -CapabilityHosts $hosts -Connections $connections }
if ($configured) {
    $null = Assert-ProjectStoreBindings -Project $project -ExpectedStores $stores -CapabilityHosts $hosts -Connections $connections
}
if ($hosts.Count -or -not $configured) {
    $accountHosts = @(Get-ResourceCollection "$management$accountId/capabilityHosts?api-version=2025-06-01")
    Assert-ProjectHostBindings -ExpectedStores $stores -CapabilityHosts $accountHosts -Connections $connections
}
$storeState = Get-BackingStoreState
if ($configured) {
    if (-not $storeState.Ready) { throw 'Project provisioning is configured but its backing stores are incomplete. Wait for provisioning or investigate; no replacement host will be created.' }
    Write-Host 'Project provisioning and backing stores are ready. No Azure writes are needed. Run access next.'
    @{ stage = 'provisioning'; status = 'Ready'; changes = @() } | ConvertTo-Json -Depth 10
    return
}
if ($storeState.HasProjectData) { throw 'Project data exists without effective settings or a healthy host. Inspect this partial configuration before provisioning.' }
$templates = @{
    roles = Join-Path $PSScriptRoot '..\infra\modules\project-provisioning-access.bicep'
    host = Join-Path $PSScriptRoot '..\infra\modules\project-capability-host.bicep'
}
$templateParameters = @{
    roles = @{ storageAccountName = $names.storage; cosmosAccountName = $names.cosmos; projectPrincipalId = $principalId }
    host = @{
        accountName = $names.foundry; projectName = $config.projectName
        blobConnectionName = $accountHosts[0].properties.storageConnections[0]
        cosmosConnectionName = $accountHosts[0].properties.threadStorageConnections[0]
        searchConnectionName = $accountHosts[0].properties.vectorStoreConnections[0]
    }
}
$roleScopes = @{
    $stores.blobStore = "/subscriptions/$($context.SubscriptionId)/providers/Microsoft.Authorization/roleDefinitions/17d1049b-9a84-46fb-8f53-869881c3d3ab"
    $stores.documentStore = "/subscriptions/$($context.SubscriptionId)/providers/Microsoft.Authorization/roleDefinitions/230815da-be43-4aae-9cb4-875f7bd000aa"
}
Write-Host "Provisioning targets only project '$($config.projectName)' in '$($names.spokeResourceGroup)'; account, models and networking are not redeployed."
$previews = @{ roles = (Invoke-ProvisioningTemplate roles 'what-if'); host = (Invoke-ProvisioningTemplate host 'what-if') }
if (-not $Apply) {
    $previews | ConvertTo-Json -Depth 100
    return
}
$null = Invoke-ProvisioningTemplate roles 'create'
foreach ($scope in $roleScopes.Keys) {
    $visible = $false
    for ($attempt = 0; $attempt -lt 30; $attempt++) {
        $assignments = @(Invoke-AzureCli @('role', 'assignment', 'list', '--scope', $scope,
            '--assignee-object-id', $principalId, '--subscription', $context.SubscriptionId))
        $visible = @($assignments | Where-Object {
            $_.scope -ieq $scope -and $_.principalId -ieq $principalId -and $_.roleDefinitionId -ieq $roleScopes[$scope]
        }).Count -eq 1
        if ($visible) { break }
        Start-Sleep -Seconds 10
    }
    if (-not $visible) { throw 'Project provisioning role assignment was not verified at its exact resource scope. No host was created.' }
}
Write-Host 'Provisioning roles verified. Allowing 60 seconds for RBAC propagation before host creation.'
Start-Sleep -Seconds 60
$latestProject = Invoke-AzureCli @('rest', '--method', 'get', '--url', $projectUrl)
$latestHosts = @(Get-ResourceCollection $hostsUrl)
if ($latestProject.identity.principalId -ine $principalId -or
    $latestProject.properties.provisioningState -ne 'Succeeded' -or
    $latestProject.properties['capabilitySettings'] -or $latestHosts.Count) {
    throw 'Project configuration changed during provisioning. Inspect and rerun; no existing host will be overwritten.'
}
$accountHosts = @(Get-ResourceCollection "$management$accountId/capabilityHosts?api-version=2025-06-01")
$connections = @(Get-ResourceCollection "$management$projectId/connections?api-version=2025-06-01")
Assert-ProjectHostBindings -ExpectedStores $stores -CapabilityHosts $accountHosts -Connections $connections
foreach ($binding in @(
    @{ Property = 'storageConnections'; Parameter = 'blobConnectionName' },
    @{ Property = 'threadStorageConnections'; Parameter = 'cosmosConnectionName' },
    @{ Property = 'vectorStoreConnections'; Parameter = 'searchConnectionName' }
)) {
    if ($accountHosts[0].properties[$binding.Property][0] -ne $templateParameters.host[$binding.Parameter]) {
        throw 'Account host connections changed during provisioning. Inspect before creating a project host.'
    }
}
if ((Get-BackingStoreState).HasProjectData) { throw 'Project backing data appeared during provisioning. Inspect before creating a project host.' }
$null = Invoke-ProvisioningTemplate host 'what-if'
$null = Invoke-ProvisioningTemplate host 'create'
$hosts = @(Get-ResourceCollection $hostsUrl)
Assert-ProjectHostBindings -ExpectedStores $stores -CapabilityHosts $hosts -Connections $connections
for ($attempt = 0; $attempt -lt 30; $attempt++) {
    $storeState = Get-BackingStoreState
    if ($storeState.Ready) {
        Write-Host 'Project host and service-created Blob/Cosmos backing stores verified. Run access next for scoped runtime roles.'
        return
    }
    Start-Sleep -Seconds 10
}
throw 'Project host deployment succeeded but backing stores are incomplete. Inspect provisioning before access; no substitute stores or broad data roles were created.'
