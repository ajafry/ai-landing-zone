param accountName string
param projectName string
param location string
param tags object
param capabilitySettings {
  blobStore: string
  documentStore: string
  vectorStore: string
}

resource account 'Microsoft.CognitiveServices/accounts@2025-06-01' existing = {
  name: accountName
}

resource project 'Microsoft.CognitiveServices/accounts/projects@2026-07-15-preview' = {
  parent: account
  name: projectName
  location: location
  tags: tags
  identity: { type: 'SystemAssigned' }
  properties: {
    displayName: projectName
    description: 'Private standard Agent Service project with customer-owned data stores.'
    capabilitySettings: capabilitySettings
  }
}
