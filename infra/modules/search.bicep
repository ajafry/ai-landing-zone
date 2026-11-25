import { Configuration } from '../types.bicep'

param config Configuration
param name string
param tags object
param subnetId string
param dnsZoneId string
param workspaceId string

resource search 'Microsoft.Search/searchServices@2025-05-01' = {
  name: name
  location: config.location
  tags: tags
  sku: { name: config.services.searchSku }
  identity: { type: 'SystemAssigned' }
  properties: {
    replicaCount: config.services.searchReplicas
    partitionCount: config.services.searchPartitions
    hostingMode: 'Default'
    publicNetworkAccess: 'Disabled'
    disableLocalAuth: true
    networkRuleSet: { ipRules: [], bypass: 'None' }
  }
}

resource logs 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  scope: search
  name: 'central-logs'
  properties: {
    workspaceId: workspaceId
    logs: [{ categoryGroup: 'allLogs', enabled: true }]
  }
}

module endpoint './private-endpoint.bicep' = {
  name: 'search-private-endpoint'
  params: {
    location: config.location
    name: 'pe-${name}'
    tags: tags
    subnetId: subnetId
    resourceId: search.id
    groupId: 'searchService'
    dnsZoneIds: [dnsZoneId]
  }
}
