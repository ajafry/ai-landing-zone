import { Configuration } from '../types.bicep'

param config Configuration
param names object
param tags object
param hubVnetId string
param firewallPrivateIp string

resource routes 'Microsoft.Network/routeTables@2024-05-01' = {
  name: 'rt-${names.spokeVnet}'
  location: config.location
  tags: tags
  properties: {
    disableBgpRoutePropagation: true
    routes: [
      {
        name: 'DefaultViaHubFirewall'
        properties: {
          addressPrefix: '0.0.0.0/0'
          nextHopType: 'VirtualAppliance'
          nextHopIpAddress: firewallPrivateIp
        }
      }
    ]
  }
}

resource endpointNsg 'Microsoft.Network/networkSecurityGroups@2024-05-01' = {
  name: 'nsg-${names.spokeVnet}-endpoints'
  location: config.location
  tags: tags
  properties: {
    securityRules: [
      {
        name: 'HttpsFromJumpbox'
        properties: {
          priority: 100
          direction: 'Inbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourceAddressPrefix: config.network.jumpboxSubnetPrefix
          sourcePortRange: '*'
          destinationAddressPrefix: config.network.privateEndpointSubnetPrefix
          destinationPortRange: '443'
        }
      }
      {
        name: 'PrivateAgentDataAccess'
        properties: {
          priority: 110
          direction: 'Inbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourceAddressPrefix: config.network.agentSubnetPrefix
          sourcePortRange: '*'
          destinationAddressPrefix: config.network.privateEndpointSubnetPrefix
          // Cosmos DB direct mode over Private Link can use the full TCP port range.
          destinationPortRange: '*'
        }
      }
      {
        name: 'DenyOtherInbound'
        properties: {
          priority: 4000
          direction: 'Inbound'
          access: 'Deny'
          protocol: '*'
          sourceAddressPrefix: '*'
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
          destinationPortRange: '*'
        }
      }
    ]
  }
}

resource vnet 'Microsoft.Network/virtualNetworks@2024-05-01' = {
  name: names.spokeVnet
  location: config.location
  tags: tags
  properties: {
    addressSpace: { addressPrefixes: [config.network.spokeAddressPrefix] }
    dhcpOptions: { dnsServers: [firewallPrivateIp] }
    subnets: [
      {
        name: config.network.agentSubnetName
        properties: {
          addressPrefix: config.network.agentSubnetPrefix
          routeTable: { id: routes.id }
          defaultOutboundAccess: false
          delegations: [
            {
              name: 'foundry-agent-injection'
              properties: { serviceName: 'Microsoft.App/environments' }
            }
          ]
        }
      }
      {
        name: config.network.privateEndpointSubnetName
        properties: {
          addressPrefix: config.network.privateEndpointSubnetPrefix
          privateEndpointNetworkPolicies: 'Enabled'
          networkSecurityGroup: { id: endpointNsg.id }
          defaultOutboundAccess: false
        }
      }
    ]
  }
}

module peer './peering.bicep' = {
  name: 'spoke-to-hub'
  params: {
    localVnetName: vnet.name
    remoteVnetId: hubVnetId
    peeringName: 'spoke-to-hub'
  }
}

output id string = vnet.id
output endpointSubnetId string = '${vnet.id}/subnets/${config.network.privateEndpointSubnetName}'
