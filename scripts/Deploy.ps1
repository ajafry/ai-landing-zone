#Requires -Version 7.2
[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateSet('hub', 'foundation', 'foundry', 'access')][string] $Stage,
    [string] $ConfigurationPath = (Join-Path $PSScriptRoot '..\infra\config.default.json'),
    [switch] $Apply,
    [switch] $QuotaReviewed,
    [Security.SecureString] $AdminPassword
)
. (Join-Path $PSScriptRoot 'Common.ps1')

$config = Get-Configuration $ConfigurationPath
$context = Get-InteractiveAzureContext
$template = Join-Path $PSScriptRoot '..\infra\main.bicep'
$parameters = @{
    stage = @{ value = $Stage }
    config = @{ value = $config }
    userObjectId = @{ value = $context.UserObjectId }
}
if ($Stage -eq 'foundation') { $null = Get-DeploymentNames $config 'hub' }
if ($Stage -eq 'foundry') {
    $null = Get-DeploymentNames $config 'foundation'
    if ($Apply) {
        if (-not $QuotaReviewed) { throw 'Review Preflight.ps1 quota output, then supply -QuotaReviewed to deploy models.' }
        & (Join-Path $PSScriptRoot 'Test-PrivateConnectivity.ps1') -ConfigurationPath $ConfigurationPath -FoundationOnly
    }
}
if ($Stage -eq 'access') {
    $names = Get-DeploymentNames $config 'foundry'
    $projectUrl = "https://management.azure.com/subscriptions/$($context.SubscriptionId)/resourceGroups/$($names.spokeResourceGroup)/providers/Microsoft.CognitiveServices/accounts/$($names.foundry)/projects/$($config.projectName)?api-version=2026-07-15-preview"
    $project = Invoke-AzureCli @('rest', '--method', 'get', '--url', $projectUrl)
    if ($project.identity.principalId -notmatch '^[a-fA-F0-9-]{36}$') { throw 'Project managed identity was not provisioned.' }
    $parameters.projectPrincipalId = @{ value = $project.identity.principalId }
    $containers = @()
    $url = "https://management.azure.com/subscriptions/$($context.SubscriptionId)/resourceGroups/$($names.spokeResourceGroup)/providers/Microsoft.Storage/storageAccounts/$($names.storage)/blobServices/default/containers?api-version=2023-05-01"
    do {
        $page = Invoke-AzureCli @('rest', '--method', 'get', '--url', $url)
        $containers += @($page.value)
        $url = $page['nextLink']
    } while ($url)
    $files = @($containers | Where-Object { $_.name -like '*-azureml-blobstore' })
    $agents = @($containers | Where-Object { $_.name -like '*-azureml-agent' })
    if ($files.Count -ne 1 -or $agents.Count -ne 1) {
        throw 'Expected exactly one Foundry file container and one agent container in this dedicated storage account. Inspect capability provisioning; do not grant account-wide data-owner access.'
    }
    $parameters.blobContainerName = @{ value = $files[0].name.Split('/')[-1] }
    $parameters.agentContainerName = @{ value = $agents[0].name.Split('/')[-1] }
}
if ($Stage -eq 'hub') {
    if (-not $AdminPassword) { $AdminPassword = Read-Host 'Windows local bootstrap password (use Entra ID for normal login)' -AsSecureString }
    $plainPassword = [Net.NetworkCredential]::new('', $AdminPassword).Password
    if ($plainPassword.Length -lt 12 -or $plainPassword.Length -gt 123 -or
        @('[a-z]', '[A-Z]', '[0-9]', '[^a-zA-Z0-9]' | Where-Object { $plainPassword -cmatch $_ }).Count -lt 3) {
        throw 'Use a 12-123 character bootstrap password with at least three character categories.'
    }
    $parameters.adminPassword = @{ value = $plainPassword }
}

$parameterFile = New-TemporaryFile
try {
    if (-not $IsWindows) { throw 'This deployment wrapper requires Windows to protect its temporary parameter file with an ACL.' }
    $acl = [Security.AccessControl.FileSecurity]::new()
    $acl.SetAccessRuleProtection($true, $false)
    $sid = [Security.Principal.WindowsIdentity]::GetCurrent().User
    $acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new($sid, 'FullControl', 'Allow'))
    Set-Acl -LiteralPath $parameterFile.FullName -AclObject $acl
    $document = @{ '$schema' = 'https://schema.management.azure.com/schemas/2019-04-01/deploymentParameters.json#'
        contentVersion = '1.0.0.0'; parameters = $parameters }
    $document | ConvertTo-Json -Depth 100 | Set-Content -LiteralPath $parameterFile.FullName -Encoding utf8
    $parameters.Remove('adminPassword')
    $plainPassword = $null
    $verb = if ($Apply) { 'create' } else { 'what-if' }
    $arguments = @('deployment', 'sub', $verb, '--name', (Get-StageDeploymentName $config $Stage),
        '--location', $config.location, '--subscription', $context.SubscriptionId,
        '--template-file', $template, '--parameters', "@$($parameterFile.FullName)")
    if (-not $Apply) { $arguments += '--no-pretty-print' }
    $result = Invoke-AzureCli $arguments
    if ($Apply) {
        if ($result.properties.provisioningState -ne 'Succeeded') { throw "The $Stage deployment did not succeed." }
        if ($Stage -eq 'hub') {
            Set-PrivateJumpboxDisk -Names $result.properties.outputs.resourceNames.value -SubscriptionId $context.SubscriptionId
        }
        Write-Host "$Stage deployment succeeded."
        if ($Stage -eq 'foundry') { Write-Host 'Run the access stage next; the project is not runtime-ready until its data roles are assigned.' }
        if ($Stage -eq 'access') { Write-Host 'Allow RBAC propagation, then run Test-PrivateConnectivity.ps1 from the jumpbox.' }
    } else {
        $result | ConvertTo-Json -Depth 100
    }
} finally {
    $parameters.Remove('adminPassword')
    $plainPassword = $null
    Remove-Item -LiteralPath $parameterFile.FullName -Force
}
