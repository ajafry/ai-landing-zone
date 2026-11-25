import { Configuration } from '../types.bicep'

param config Configuration
param names object
param tags object
param userObjectId string
param hubResourceGroupName string

resource hubVnet 'Microsoft.Network/virtualNetworks@2024-05-01' existing = {
  name: names.hubVnet
  scope: resourceGroup(hubResourceGroupName)
}

resource firewall 'Microsoft.Network/azureFirewalls@2024-05-01' existing = {
  name: names.firewall
  scope: resourceGroup(hubResourceGroupName)
}

module network './spoke-network.bicep' = {
  name: 'spoke-network'
  params: {
    config: config
    names: names
    tags: tags
    hubVnetId: hubVnet.id
    firewallPrivateIp: firewall.properties.ipConfigurations[0].properties.privateIPAddress
  }
}

module dns './private-dns.bicep' = {
  name: 'shared-private-dns'
  params: {
    tags: tags
    hubVnetId: hubVnet.id
    spokeVnetId: network.outputs.id
  }
}

module storage './storage.bicep' = {
  name: 'private-storage'
  params: {
    config: config
    name: names.storage
    tags: tags
    userObjectId: userObjectId
    subnetId: network.outputs.endpointSubnetId
    dnsZoneId: dns.outputs.zoneIds['privatelink.blob.${environment().suffixes.storage}']
    workspaceId: monitor.outputs.workspaceId
  }
}

module cosmos './cosmos.bicep' = {
  name: 'private-cosmos'
  params: {
    config: config
    name: names.cosmos
    tags: tags
    userObjectId: userObjectId
    subnetId: network.outputs.endpointSubnetId
    dnsZoneId: dns.outputs.zoneIds['privatelink.documents.azure.com']
    workspaceId: monitor.outputs.workspaceId
  }
}

module search './search.bicep' = {
  name: 'private-search'
  params: {
    config: config
    name: names.search
    tags: tags
    subnetId: network.outputs.endpointSubnetId
    dnsZoneId: dns.outputs.zoneIds['privatelink.search.windows.net']
    workspaceId: monitor.outputs.workspaceId
  }
}

module vault './key-vault.bicep' = {
  name: 'private-key-vault'
  params: {
    config: config
    name: names.keyVault
    tags: tags
    subnetId: network.outputs.endpointSubnetId
    dnsZoneId: dns.outputs.zoneIds['privatelink.vaultcore.azure.net']
    workspaceId: monitor.outputs.workspaceId
  }
}

module monitor './monitoring.bicep' = {
  name: 'private-monitoring'
  params: {
    config: config
    names: names
    tags: tags
    subnetId: network.outputs.endpointSubnetId
    dnsZoneIds: [
      dns.outputs.zoneIds['privatelink.monitor.azure.com']
      dns.outputs.zoneIds['privatelink.oms.opinsights.azure.com']
      dns.outputs.zoneIds['privatelink.ods.opinsights.azure.com']
      dns.outputs.zoneIds['privatelink.agentsvc.azure-automation.net']
      dns.outputs.zoneIds['privatelink.blob.${environment().suffixes.storage}']
    ]
  }
}

resource reader 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(resourceGroup().id, userObjectId, 'spoke-reader')
  properties: {
    principalId: userObjectId
    principalType: 'User'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', 'acdd72a7-3385-48ef-bd42-f606fba81ae7')
  }
}

output spokeVnetId string = network.outputs.id
output workspaceId string = monitor.outputs.workspaceId
