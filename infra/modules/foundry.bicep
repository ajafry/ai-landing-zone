import { Configuration } from '../types.bicep'

param config Configuration
param names object
param tags object

resource storage 'Microsoft.Storage/storageAccounts@2023-05-01' existing = { name: names.storage }
resource cosmos 'Microsoft.DocumentDB/databaseAccounts@2024-05-15' existing = { name: names.cosmos }
resource search 'Microsoft.Search/searchServices@2023-11-01' existing = { name: names.search }
resource vnet 'Microsoft.Network/virtualNetworks@2024-05-01' existing = { name: names.spokeVnet }
resource workspace 'Microsoft.OperationalInsights/workspaces@2023-09-01' existing = { name: names.logAnalytics }

// Capability settings provision BYO connections with the caller identity, not shared keys.
resource account 'Microsoft.CognitiveServices/accounts@2026-07-15-preview' = {
  name: names.foundry
  location: config.location
  tags: tags
  kind: 'AIServices'
  sku: { name: 'S0' }
  identity: { type: 'SystemAssigned' }
  properties: {
    allowProjectManagement: true
    defaultProject: config.projectName
    customSubDomainName: names.foundry
    disableLocalAuth: true
    publicNetworkAccess: 'Disabled'
    networkAcls: { defaultAction: 'Deny', bypass: 'None', ipRules: [], virtualNetworkRules: [] }
    restrictOutboundNetworkAccess: true
    allowedFqdnList: [
      '${names.storage}.blob.${environment().suffixes.storage}'
      '${names.cosmos}.documents.azure.com'
      '${names.search}.search.windows.net'
      '${names.keyVault}${environment().suffixes.keyvaultDns}'
    ]
    networkInjections: [
      {
        scenario: 'agent'
        subnetArmId: '${vnet.id}/subnets/${config.network.agentSubnetName}'
        useMicrosoftManagedNetwork: false
      }
    ]
    capabilitySettings: {
      blobStore: storage.id
      documentStore: cosmos.id
      vectorStore: search.id
    }
  }
}

module endpoint './private-endpoint.bicep' = {
  name: 'foundry-private-endpoint'
  params: {
    location: config.location
    name: 'pe-${names.foundry}'
    tags: tags
    subnetId: '${vnet.id}/subnets/${config.network.privateEndpointSubnetName}'
    resourceId: account.id
    groupId: 'account'
    dnsZoneIds: [
      resourceId('Microsoft.Network/privateDnsZones', 'privatelink.cognitiveservices.azure.com')
      resourceId('Microsoft.Network/privateDnsZones', 'privatelink.openai.azure.com')
      resourceId('Microsoft.Network/privateDnsZones', 'privatelink.services.ai.azure.com')
    ]
  }
}

module project './foundry-project.bicep' = {
  name: 'foundry-project'
  params: {
    accountName: account.name
    projectName: config.projectName
    location: config.location
    tags: tags
    capabilitySettings: {
      blobStore: storage.id
      documentStore: cosmos.id
      vectorStore: search.id
    }
  }
  dependsOn: [endpoint]
}

@batchSize(1)
resource models 'Microsoft.CognitiveServices/accounts/deployments@2025-06-01' = [for model in config.models: {
  parent: account
  name: model.deploymentName
  sku: { name: model.sku, capacity: model.capacity }
  properties: {
    model: { format: 'OpenAI', name: model.modelName, version: model.version }
    versionUpgradeOption: 'NoAutoUpgrade'
  }
}]

resource logs 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  scope: account
  name: 'central-logs'
  properties: {
    workspaceId: workspace.id
    logs: [{ categoryGroup: 'allLogs', enabled: true }]
    metrics: [{ category: 'AllMetrics', enabled: true }]
  }
}
