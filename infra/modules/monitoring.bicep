import { Configuration } from '../types.bicep'

param config Configuration
param names object
param tags object
param subnetId string
param dnsZoneIds string[]

resource workspace 'Microsoft.OperationalInsights/workspaces@2023-09-01' = {
  name: names.logAnalytics
  location: config.location
  tags: tags
  properties: {
    sku: { name: 'PerGB2018' }
    retentionInDays: config.services.logRetentionDays
    workspaceCapping: { dailyQuotaGb: config.services.logDailyQuotaGB }
    publicNetworkAccessForIngestion: 'Disabled'
    publicNetworkAccessForQuery: 'Disabled'
    features: { disableLocalAuth: true }
  }
}

resource insights 'Microsoft.Insights/components@2020-02-02' = {
  name: names.appInsights
  location: config.location
  tags: tags
  kind: 'web'
  properties: {
    Application_Type: 'web'
    WorkspaceResourceId: workspace.id
    publicNetworkAccessForIngestion: 'Disabled'
    publicNetworkAccessForQuery: 'Disabled'
    DisableLocalAuth: true
  }
}

resource scope 'Microsoft.Insights/privateLinkScopes@2021-09-01' = {
  name: names.monitorScope
  location: 'global'
  tags: tags
  properties: {
    accessModeSettings: {
      ingestionAccessMode: 'PrivateOnly'
      queryAccessMode: 'PrivateOnly'
      exclusions: []
    }
  }
}

resource workspaceLink 'Microsoft.Insights/privateLinkScopes/scopedResources@2021-09-01' = {
  parent: scope
  name: 'workspace'
  properties: { linkedResourceId: workspace.id }
}

resource insightsLink 'Microsoft.Insights/privateLinkScopes/scopedResources@2021-09-01' = {
  parent: scope
  name: 'appinsights'
  properties: { linkedResourceId: insights.id }
}

module endpoint './private-endpoint.bicep' = {
  name: 'monitor-private-endpoint'
  params: {
    location: config.location
    name: 'pe-${names.monitorScope}'
    tags: tags
    subnetId: subnetId
    resourceId: scope.id
    groupId: 'azuremonitor'
    dnsZoneIds: dnsZoneIds
  }
  dependsOn: [workspaceLink, insightsLink]
}

output workspaceId string = workspace.id
