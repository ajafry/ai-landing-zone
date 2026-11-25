import { Configuration } from '../types.bicep'

param config Configuration
param name string
param tags object
param userObjectId string
param subnetId string
param dnsZoneId string
param workspaceId string

resource account 'Microsoft.DocumentDB/databaseAccounts@2024-05-15' = {
  name: name
  location: config.location
  tags: tags
  kind: 'GlobalDocumentDB'
  properties: {
    databaseAccountOfferType: 'Standard'
    locations: [{ locationName: config.location, failoverPriority: 0, isZoneRedundant: false }]
    consistencyPolicy: { defaultConsistencyLevel: 'Session' }
    publicNetworkAccess: 'Disabled'
    disableLocalAuth: true
    networkAclBypass: 'None'
    isVirtualNetworkFilterEnabled: true
    virtualNetworkRules: []
    ipRules: []
    enableAutomaticFailover: false
    capacity: { totalThroughputLimit: config.services.cosmosTotalThroughputLimit }
    backupPolicy: {
      type: 'Continuous'
      continuousModeProperties: { tier: 'Continuous7Days' }
    }
  }
}

resource caller 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: account
  name: guid(account.id, userObjectId, 'provisioning-cosmos-operator')
  properties: {
    principalId: userObjectId
    principalType: 'User'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '230815da-be43-4aae-9cb4-875f7bd000aa')
  }
}

resource logs 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  scope: account
  name: 'central-logs'
  properties: {
    workspaceId: workspaceId
    logs: [{ categoryGroup: 'allLogs', enabled: true }]
  }
}

module endpoint './private-endpoint.bicep' = {
  name: 'cosmos-private-endpoint'
  params: {
    location: config.location
    name: 'pe-${name}'
    tags: tags
    subnetId: subnetId
    resourceId: account.id
    groupId: 'Sql'
    dnsZoneIds: [dnsZoneId]
  }
}
