import { Configuration } from '../types.bicep'

param config Configuration
param name string
param tags object
param subnetId string
param dnsZoneId string
param workspaceId string

resource vault 'Microsoft.KeyVault/vaults@2023-07-01' = {
  name: name
  location: config.location
  tags: tags
  properties: {
    tenantId: subscription().tenantId
    sku: { family: 'A', name: config.services.keyVaultSku }
    enableRbacAuthorization: true
    enableSoftDelete: true
    softDeleteRetentionInDays: 90
    enablePurgeProtection: true
    publicNetworkAccess: 'Disabled'
    networkAcls: { defaultAction: 'Deny', bypass: 'None' }
    accessPolicies: []
  }
}

resource logs 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  scope: vault
  name: 'central-logs'
  properties: {
    workspaceId: workspaceId
    logs: [{ categoryGroup: 'allLogs', enabled: true }]
  }
}

module endpoint './private-endpoint.bicep' = {
  name: 'vault-private-endpoint'
  params: {
    location: config.location
    name: 'pe-${name}'
    tags: tags
    subnetId: subnetId
    resourceId: vault.id
    groupId: 'vault'
    dnsZoneIds: [dnsZoneId]
  }
}
