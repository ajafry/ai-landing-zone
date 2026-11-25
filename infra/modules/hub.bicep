import { Configuration } from '../types.bicep'

param config Configuration
param names object
param tags object
param userObjectId string
@secure()
param adminPassword string

var location = config.location
var network = config.network

resource jumpboxRoutes 'Microsoft.Network/routeTables@2024-05-01' = {
  name: 'rt-${names.jumpbox}'
  location: location
  tags: tags
  properties: { disableBgpRoutePropagation: true }
}

resource bastionNsg 'Microsoft.Network/networkSecurityGroups@2024-05-01' = {
  name: 'nsg-${names.bastion}'
  location: location
  tags: tags
  properties: {
    securityRules: [
      {
        name: 'HttpsFromInternet'
        properties: {
          priority: 100
          direction: 'Inbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourceAddressPrefix: 'Internet'
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
          destinationPortRange: '443'
        }
      }
      {
        name: 'GatewayManager'
        properties: {
          priority: 110
          direction: 'Inbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourceAddressPrefix: 'GatewayManager'
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
          destinationPortRange: '443'
        }
      }
      {
        name: 'LoadBalancer'
        properties: {
          priority: 120
          direction: 'Inbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourceAddressPrefix: 'AzureLoadBalancer'
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
          destinationPortRange: '443'
        }
      }
      {
        name: 'BastionInternalInbound'
        properties: {
          priority: 130
          direction: 'Inbound'
          access: 'Allow'
          protocol: '*'
          sourceAddressPrefix: 'VirtualNetwork'
          sourcePortRange: '*'
          destinationAddressPrefix: 'VirtualNetwork'
          destinationPortRanges: ['8080', '5701']
        }
      }
      {
        name: 'SshRdpToVirtualNetwork'
        properties: {
          priority: 100
          direction: 'Outbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourceAddressPrefix: '*'
          sourcePortRange: '*'
          destinationAddressPrefix: 'VirtualNetwork'
          destinationPortRanges: ['22', '3389']
        }
      }
      {
        name: 'AzureControlPlane'
        properties: {
          priority: 110
          direction: 'Outbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourceAddressPrefix: '*'
          sourcePortRange: '*'
          destinationAddressPrefix: 'AzureCloud'
          destinationPortRange: '443'
        }
      }
      {
        name: 'BastionInternalOutbound'
        properties: {
          priority: 120
          direction: 'Outbound'
          access: 'Allow'
          protocol: '*'
          sourceAddressPrefix: 'VirtualNetwork'
          sourcePortRange: '*'
          destinationAddressPrefix: 'VirtualNetwork'
          destinationPortRanges: ['8080', '5701']
        }
      }
      {
        name: 'CertificateValidation'
        properties: {
          priority: 130
          direction: 'Outbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourceAddressPrefix: '*'
          sourcePortRange: '*'
          destinationAddressPrefix: 'Internet'
          destinationPortRange: '80'
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
      {
        name: 'DenyOtherOutbound'
        properties: {
          priority: 4000
          direction: 'Outbound'
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

resource jumpboxNsg 'Microsoft.Network/networkSecurityGroups@2024-05-01' = {
  name: 'nsg-${names.jumpbox}'
  location: location
  tags: tags
  properties: {
    securityRules: [
      {
        name: 'RdpFromBastionOnly'
        properties: {
          priority: 100
          direction: 'Inbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourceAddressPrefix: network.bastionSubnetPrefix
          sourcePortRange: '*'
          destinationAddressPrefix: network.jumpboxSubnetPrefix
          destinationPortRange: '3389'
        }
      }
      {
        name: 'AzureDns'
        properties: {
          priority: 100
          direction: 'Outbound'
          access: 'Allow'
          protocol: '*'
          sourceAddressPrefix: '*'
          sourcePortRange: '*'
          destinationAddressPrefixes: ['168.63.129.16', network.firewallSubnetPrefix]
          destinationPortRange: '53'
        }
      }
      {
        name: 'VmPlatform'
        properties: {
          priority: 110
          direction: 'Outbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourceAddressPrefix: '*'
          sourcePortRange: '*'
          destinationAddressPrefixes: ['168.63.129.16', '169.254.169.254']
          destinationPortRanges: ['80', '443', '32526']
        }
      }
      {
        name: 'WebThroughFirewallOrPrivateLink'
        properties: {
          priority: 120
          direction: 'Outbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourceAddressPrefix: '*'
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
          destinationPortRanges: ['80', '443', '1688']
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
      {
        name: 'DenyOtherOutbound'
        properties: {
          priority: 4000
          direction: 'Outbound'
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
  name: names.hubVnet
  location: location
  tags: tags
  properties: {
    addressSpace: { addressPrefixes: [network.hubAddressPrefix] }
    subnets: [
      {
        name: 'AzureBastionSubnet'
        properties: {
          addressPrefix: network.bastionSubnetPrefix
          networkSecurityGroup: { id: bastionNsg.id }
          defaultOutboundAccess: false
        }
      }
      {
        name: 'AzureFirewallSubnet'
        properties: { addressPrefix: network.firewallSubnetPrefix }
      }
      {
        name: 'snet-jumpbox'
        properties: {
          addressPrefix: network.jumpboxSubnetPrefix
          networkSecurityGroup: { id: jumpboxNsg.id }
          routeTable: { id: jumpboxRoutes.id }
          defaultOutboundAccess: false
        }
      }
    ]
  }
}

module firewall './firewall.bicep' = {
  name: 'hub-firewall'
  params: {
    config: config
    names: names
    tags: tags
    firewallSubnetId: '${vnet.id}/subnets/AzureFirewallSubnet'
  }
}

resource defaultRoute 'Microsoft.Network/routeTables/routes@2024-05-01' = {
  parent: jumpboxRoutes
  name: 'DefaultViaFirewall'
  properties: {
    addressPrefix: '0.0.0.0/0'
    nextHopType: 'VirtualAppliance'
    nextHopIpAddress: firewall.outputs.privateIp
  }
}

resource bastionIp 'Microsoft.Network/publicIPAddresses@2024-05-01' = {
  name: 'pip-${names.bastion}'
  location: location
  tags: tags
  sku: { name: 'Standard' }
  properties: { publicIPAllocationMethod: 'Static' }
}

resource bastion 'Microsoft.Network/bastionHosts@2024-05-01' = {
  name: names.bastion
  location: location
  tags: tags
  sku: { name: config.hub.bastionSku }
  properties: {
    enableTunneling: true
    enableIpConnect: false
    enableShareableLink: false
    ipConfigurations: [
      {
        name: 'bastion-ip'
        properties: {
          subnet: { id: '${vnet.id}/subnets/AzureBastionSubnet' }
          publicIPAddress: { id: bastionIp.id }
        }
      }
    ]
  }
}

module vm './jumpbox.bicep' = {
  name: 'hub-jumpbox'
  params: {
    config: config
    name: names.jumpbox
    tags: tags
    subnetId: '${vnet.id}/subnets/snet-jumpbox'
    userObjectId: userObjectId
    adminPassword: adminPassword
    dnsServerIp: firewall.outputs.privateIp
  }
  dependsOn: [defaultRoute]
}

resource reader 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(resourceGroup().id, userObjectId, 'hub-reader')
  properties: {
    principalId: userObjectId
    principalType: 'User'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', 'acdd72a7-3385-48ef-bd42-f606fba81ae7')
  }
}
