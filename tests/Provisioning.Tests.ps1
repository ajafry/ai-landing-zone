#Requires -Version 7.2
. (Join-Path $PSScriptRoot '..\scripts\Common.ps1')

function Assert-ProvisioningTest {
    param([bool] $Condition, [string] $Message)
    if (-not $Condition) { throw $Message }
}

$subscriptionId = 'aaaaaaaa-1111-2222-3333-bbbbbbbbbbbb'
$principalId = 'bbbbbbbb-1111-2222-3333-cccccccccccc'
$workspaceId = 'cccccccc-1111-2222-3333-dddddddddddd'
$names = @{
    spokeResourceGroup = 'rg-test-spoke'; foundry = 'ai-test'
    storage = 'teststorage'; cosmos = 'testcosmos'; search = 'testsearch'
}
$root = "/subscriptions/$subscriptionId/resourceGroups/$($names.spokeResourceGroup)/providers"
$accountId = "$root/Microsoft.CognitiveServices/accounts/$($names.foundry)"
$projectId = "$accountId/projects/$((Get-Configuration).projectName)"
$stores = @{
    blobStore = "$root/Microsoft.Storage/storageAccounts/$($names.storage)"
    documentStore = "$root/Microsoft.DocumentDB/databaseAccounts/$($names.cosmos)"
    vectorStore = "$root/Microsoft.Search/searchServices/$($names.search)"
}
$roleScopes = @{
    $stores.blobStore = "/subscriptions/$subscriptionId/providers/Microsoft.Authorization/roleDefinitions/17d1049b-9a84-46fb-8f53-869881c3d3ab"
    $stores.documentStore = "/subscriptions/$subscriptionId/providers/Microsoft.Authorization/roleDefinitions/230815da-be43-4aae-9cb4-875f7bd000aa"
}
$hostFixture = @{
    name = 'agents'
    properties = @{
        provisioningState = 'Succeeded'; capabilityHostKind = 'Agents'
        storageConnections = @('blob'); threadStorageConnections = @('cosmos'); vectorStoreConnections = @('search')
    }
}
$connections = @(
    @{ name = 'blob'; properties = @{ authType = 'AAD'; target = 'https://teststorage.blob.core.windows.net/'; metadata = @{ ResourceId = $stores.blobStore } } },
    @{ name = 'cosmos'; properties = @{ authType = 'AAD'; target = 'https://testcosmos.documents.azure.com/'; metadata = @{ ResourceId = $stores.documentStore } } },
    @{ name = 'search'; properties = @{ authType = 'AAD'; target = 'https://testsearch.search.windows.net/'; metadata = @{ ResourceId = $stores.vectorStore } } }
)

function az {
    $arguments = @($args)
    $global:LASTEXITCODE = 0
    $result = switch ($arguments[0]) {
        'account' { @{ environmentName = 'AzureCloud'; id = $subscriptionId; user = @{ type = 'user' } }; break }
        'ad' { @{ id = 'dddddddd-1111-2222-3333-eeeeeeeeeeee' }; break }
        'deployment' {
            if ($arguments[2] -eq 'show') {
                @{ properties = @{ provisioningState = 'Succeeded'; outputs = @{ resourceNames = @{ value = $names } } } }
                break
            }
            Assert-ProvisioningTest ($arguments[1] -eq 'group') 'Provisioning must not redeploy the subscription, account or networking.'
            $subscriptionIndex = [Array]::IndexOf($arguments, '--subscription')
            $groupIndex = [Array]::IndexOf($arguments, '--resource-group')
            Assert-ProvisioningTest ($arguments[$subscriptionIndex + 1] -eq $subscriptionId -and
                $arguments[$groupIndex + 1] -eq $names.spokeResourceGroup -and
                $arguments -contains 'Incremental') 'Provisioning must pin the subscription/spoke and use incremental deployment.'
            $templateIndex = [Array]::IndexOf($arguments, '--template-file')
            $part = if ($arguments[$templateIndex + 1] -like '*project-capability-host.bicep') { 'host' } else { 'roles' }
            $state.Events.Add("$($arguments[2]):$part")
            if ($arguments[2] -eq 'what-if') {
                Assert-ProvisioningTest ($arguments -contains '--no-pretty-print') 'Provisioning previews must return machine-readable changes.'
                $changes = if ($part -eq 'host') {
                    @(@{ resourceId = "$projectId/capabilityHosts/agents"; changeType = $state.HostChangeType
                        after = @{ properties = $hostFixture.properties } })
                } else {
                    @($roleScopes.Keys | ForEach-Object {
                        @{ resourceId = "$_/providers/Microsoft.Authorization/roleAssignments/role-test"; changeType = 'Create'
                            after = @{ properties = @{ roleDefinitionId = $roleScopes[$_]; principalId = $principalId; principalType = 'ServicePrincipal' } } }
                    })
                }
                @{ status = 'Succeeded'; changes = $changes }
            } elseif ($arguments[2] -eq 'create') {
                if ($part -eq 'host') {
                    Assert-ProvisioningTest ($state.Events -contains 'sleep:60' -and $state.VerifiedScopes.Count -eq 2) 'Verify exact provisioning grants and allow propagation before creating the host.'
                    $state.Hosts = @($hostFixture)
                    if (-not $state.MissingAfterCreate) { $state.StoresReady = $true }
                }
                @{ properties = @{ provisioningState = 'Succeeded' } }
            } else { throw 'Unexpected deployment verb in provisioning test.' }
            break
        }
        'role' {
            $scopeIndex = [Array]::IndexOf($arguments, '--scope')
            $scope = $arguments[$scopeIndex + 1]
            $state.VerifiedScopes.Add($scope)
            $assignment = @{ scope = $scope; principalId = $principalId; roleDefinitionId = $roleScopes[$scope] }
            if ($state.BadRoleScope) { $assignment.scope = "$scope/unexpected" }
            ,@($assignment)
            break
        }
        'rest' {
            $urlIndex = [Array]::IndexOf($arguments, '--url')
            $url = $arguments[$urlIndex + 1]
            switch -Wildcard (([uri] $url).AbsolutePath) {
                $accountId { @{ properties = @{ provisioningState = 'Succeeded'; publicNetworkAccess = 'Disabled' } }; break }
                $projectId {
                    $properties = @{ provisioningState = 'Succeeded'; internalId = $workspaceId.Replace('-', '') }
                    if ($state.Settings) { $properties.capabilitySettings = $state.Settings }
                    @{ identity = @{ principalId = $principalId }; properties = $properties }
                    break
                }
                "$projectId/capabilityHosts" { @{ value = @($state.Hosts) }; break }
                "$projectId/connections" { @{ value = $state.Connections }; break }
                "$accountId/capabilityHosts" { @{ value = @($hostFixture) }; break }
                '*blobServices/default/containers' {
                    $containers = @()
                    if ($state.StoresReady) {
                        $containers = @(@{ name = "$workspaceId-azureml-blobstore" }, @{ name = "$workspaceId-extra-azureml-agent" })
                    } elseif ($state.PartialStores) { $containers = @(@{ name = "$workspaceId-azureml-blobstore" }) }
                    # The unrelated project's containers must never count as this project's readiness.
                    $containers += @(@{ name = 'eeeeeeee-1111-2222-3333-ffffffffffff-azureml-blobstore' })
                    @{ value = $containers }
                    break
                }
                '*sqlDatabases/enterprise_memory/containers' {
                    $containers = @()
                    if ($state.StoresReady) {
                        $containers = @('thread-message-store', 'system-thread-message-store', 'agent-entity-store' |
                            ForEach-Object { @{ name = "$workspaceId-$_" } })
                    }
                    if ($state.IncompleteCosmos) { $containers = @($containers | Select-Object -First 2) }
                    @{ value = $containers }
                    break
                }
                '*sqlDatabases' { @{ value = @(@{ name = 'enterprise_memory' }) }; break }
                default { throw "Unexpected resource read in provisioning test: $url" }
            }
            break
        }
        default { throw "Unexpected Azure command in provisioning test: $($arguments -join ' ')" }
    }
    ConvertTo-Json -InputObject $result -Depth 30
}

function Start-Sleep {
    param([int] $Seconds)
    $state.Events.Add("sleep:$Seconds")
    if ($state.ChangeDuringWait -and $Seconds -eq 60) { $state.Hosts = @($hostFixture) }
}

$deploy = Join-Path $PSScriptRoot '..\scripts\Deploy.ps1'
foreach ($scenario in @('healthy-host', 'healthy-settings', 'preview', 'apply', 'wrong-settings', 'wrong-connection',
    'unhealthy-host', 'multiple-hosts', 'partial-stores', 'incomplete-cosmos', 'configured-no-stores',
    'unsafe-preview', 'bad-role-scope', 'concurrent-host', 'missing-after-create')) {
    $state = @{
        Hosts = @(); Settings = $null; Connections = $connections | ConvertTo-Json -Depth 20 | ConvertFrom-Json -AsHashtable
        StoresReady = $false; PartialStores = $false; IncompleteCosmos = $false
        MissingAfterCreate = $false; BadRoleScope = $false; ChangeDuringWait = $false
        HostChangeType = 'Create'; Events = [Collections.Generic.List[string]]::new()
        VerifiedScopes = [Collections.Generic.List[string]]::new()
    }
    $apply = $false
    $expectedError = $null
    switch ($scenario) {
        'healthy-host' { $state.Hosts = @($hostFixture); $state.StoresReady = $true; $apply = $true }
        'healthy-settings' { $state.Settings = @{} + $stores; $state.StoresReady = $true }
        'apply' { $apply = $true }
        'wrong-settings' { $state.Settings = @{} + $stores; $state.Settings.blobStore += '-wrong'; $expectedError = '*does not match*' }
        'wrong-connection' { $state.Connections[0].properties.authType = 'ApiKey'; $expectedError = '*intended AAD resource*' }
        'unhealthy-host' {
            $copy = $hostFixture | ConvertTo-Json -Depth 10 | ConvertFrom-Json -AsHashtable
            $copy.properties.provisioningState = 'Failed'
            $state.Hosts = @($copy); $expectedError = '*healthy Agents capability host*'
        }
        'multiple-hosts' { $state.Hosts = @($hostFixture, $hostFixture); $expectedError = '*healthy Agents capability host*' }
        'partial-stores' { $state.PartialStores = $true; $expectedError = '*partial configuration*' }
        'incomplete-cosmos' { $state.Hosts = @($hostFixture); $state.StoresReady = $true; $state.IncompleteCosmos = $true; $expectedError = '*backing stores are incomplete*' }
        'configured-no-stores' { $state.Settings = @{} + $stores; $expectedError = '*backing stores are incomplete*' }
        'unsafe-preview' { $state.HostChangeType = 'Modify'; $apply = $true; $expectedError = '*existing resources must not be overwritten*' }
        'bad-role-scope' { $state.BadRoleScope = $true; $apply = $true; $expectedError = '*exact resource scope*' }
        'concurrent-host' { $state.ChangeDuringWait = $true; $apply = $true; $expectedError = '*configuration changed*' }
        'missing-after-create' { $state.MissingAfterCreate = $true; $apply = $true; $expectedError = '*host deployment succeeded but backing stores are incomplete*' }
    }
    try {
        $output = & $deploy -Stage provisioning -Apply:$apply
        if ($expectedError) { throw "Expected rejection for $scenario" }
        if ($scenario -like 'healthy-*') {
            $result = $output | ConvertFrom-Json -AsHashtable
            Assert-ProvisioningTest ($state.Events.Count -eq 0 -and $result.status -eq 'Ready') 'Healthy provisioning must perform no deployments, previews, role writes or waits.'
        } elseif ($scenario -eq 'preview') {
            Assert-ProvisioningTest (($state.Events -join ',') -eq 'what-if:roles,what-if:host') 'Default provisioning must only preview both isolated templates.'
        } elseif ($scenario -eq 'apply') {
            Assert-ProvisioningTest (($state.Events -join ',') -eq 'what-if:roles,what-if:host,create:roles,sleep:60,what-if:host,create:host') 'Provisioning sequence must preview, grant, verify/wait, recheck, and create only the missing host.'
        }
    } catch {
        if (-not $expectedError -or $_.Exception.Message -notlike $expectedError) { throw }
        if ($scenario -notin @('bad-role-scope', 'concurrent-host', 'missing-after-create')) {
            Assert-ProvisioningTest (@($state.Events | Where-Object { $_ -like 'create:*' }).Count -eq 0) "Rejected $scenario must not write Azure resources."
        } elseif ($scenario -ne 'missing-after-create') {
            Assert-ProvisioningTest ($state.Events -notcontains 'create:host') 'An unverified role or concurrent host must prevent host creation.'
        }
    }
}
Write-Host 'Guarded project provisioning checks passed.'
