@description('Explicit project-host recovery for a project with no effective capability settings and no existing host. Reuses the existing healthy account host and AAD store connections.')
param accountName string
param projectName string
param capabilityHostName string = 'agents'
param blobConnectionName string
param cosmosConnectionName string
param searchConnectionName string

resource account 'Microsoft.CognitiveServices/accounts@2025-06-01' existing = {
  name: accountName
}
resource project 'Microsoft.CognitiveServices/accounts/projects@2025-06-01' existing = {
  parent: account
  name: projectName
}

resource host 'Microsoft.CognitiveServices/accounts/projects/capabilityHosts@2025-06-01' = {
  parent: project
  name: capabilityHostName
  properties: {
    // The service requires the kind, although the published Bicep type omits it.
    #disable-next-line BCP037
    capabilityHostKind: 'Agents'
    storageConnections: [blobConnectionName]
    threadStorageConnections: [cosmosConnectionName]
    vectorStoreConnections: [searchConnectionName]
  }
}
