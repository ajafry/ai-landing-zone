import { Configuration } from '../types.bicep'

param config Configuration
param name string
param tags object
param userObjectId string
param subnetId string
param dnsZoneId string
param workspaceId string

resource storage 'Microsoft.Storage/storageAccounts@2023-05-01' = {
  name: name
  location: config.location
  tags: tags
  kind: 'StorageV2'
  sku: { name: config.services.storageSku }
  properties: {
    minimumTlsVersion: 'TLS1_2'
    supportsHttpsTrafficOnly: true
    allowBlobPublicAccess: false
    allowSharedKeyAccess: false
    defaultToOAuthAuthentication: true
    publicNetworkAccess: 'Disabled'
    networkAcls: { defaultAction: 'Deny', bypass: 'None' }
    encryption: {
      keySource: 'Microsoft.Storage'
      services: {
        blob: { enabled: true }
        file: { enabled: true }
      }
    }
  }
}

resource blob 'Microsoft.Storage/storageAccounts/blobServices@2023-05-01' = {
  parent: storage
  name: 'default'
  properties: {
    deleteRetentionPolicy: { enabled: true, days: 7 }
    containerDeleteRetentionPolicy: { enabled: true, days: 7 }
  }
}

resource caller 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: storage
  name: guid(storage.id, userObjectId, 'provisioning-blob-contributor')
  properties: {
    principalId: userObjectId
    principalType: 'User'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', 'ba92f5b4-2d11-453d-a403-e96b0029c9fe')
  }
}

resource logs 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  scope: blob
  name: 'central-logs'
  properties: {
    workspaceId: workspaceId
    logs: [{ categoryGroup: 'allLogs', enabled: true }]
  }
}

module endpoint './private-endpoint.bicep' = {
  name: 'storage-blob-private-endpoint'
  params: {
    location: config.location
    name: 'pe-${name}-blob'
    tags: tags
    subnetId: subnetId
    resourceId: storage.id
    groupId: 'blob'
    dnsZoneIds: [dnsZoneId]
  }
}
