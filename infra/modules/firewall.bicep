import { Configuration } from '../types.bicep'

param config Configuration
param names object
param tags object
param firewallSubnetId string

var loginHost = replace(replace(environment().authentication.loginEndpoint, 'https://', ''), '/', '')
var identityFqdns = [
  loginHost
  '*.${loginHost}'
  'login.microsoft.com'
  '*.login.microsoft.com'
  '*.identity.azure.net'
  'control-${config.location}.identity.azure.net'
  '${config.location}.login.microsoft.com'
]
var portalFqdns = [
  replace(replace(environment().resourceManager, 'https://', ''), '/', '')
  'portal.azure.com'
  '*.portal.azure.com'
  'ai.azure.com'
  'foundry.azure.com'
  '*.ai.azure.com'
  '*.reactblade.portal.azure.net'
  '*.hosting.portal.azure.net'
  '*.hosting.portal.azure.com'
  'graph.microsoft.com'
  '*.msauth.net'
  '*.msftauth.net'
  '*.msauthimages.net'
  '*.msftauthimages.net'
  'device.${loginHost}'
  'enterpriseregistration.windows.net'
  'pas.windows.net'
  'account.live.com'
  'login.live.com'
  'aka.ms'
  'learn.microsoft.com'
  'download.microsoft.com'
  'go.microsoft.com'
  'azcliprod.blob.${environment().suffixes.storage}'
  'github.com'
  'release-assets.githubusercontent.com'
  'codeload.github.com'
]
var platformFqdns = [
  'mcr.microsoft.com'
  '*.data.mcr.microsoft.com'
  'packages.aks.azure.com'
  'acs-mirror.azureedge.net'
]

resource policy 'Microsoft.Network/firewallPolicies@2024-05-01' = {
  name: names.firewallPolicy
  location: config.location
  tags: tags
  properties: {
    sku: { tier: config.hub.firewallSku }
    threatIntelMode: 'Deny'
    // Azure DNS resolves private zones linked to the hub; no Internet DNS forwarder.
    dnsSettings: {
      servers: ['168.63.129.16']
      enableProxy: true
    }
  }
}

resource rules 'Microsoft.Network/firewallPolicies/ruleCollectionGroups@2024-05-01' = {
  parent: policy
  name: 'approved-egress'
  properties: {
    priority: 100
    ruleCollections: [
      {
        name: 'WindowsActivation'
        priority: 100
        ruleCollectionType: 'FirewallPolicyFilterRuleCollection'
        action: { type: 'Allow' }
        rules: [
          {
            name: 'Kms'
            ruleType: 'NetworkRule'
            ipProtocols: ['TCP']
            sourceAddresses: [config.network.jumpboxSubnetPrefix]
            destinationFqdns: ['kms.${environment().suffixes.storage}', 'azkms.${environment().suffixes.storage}']
            destinationPorts: ['1688']
          }
        ]
      }
      {
        name: 'JumpboxWeb'
        priority: 200
        ruleCollectionType: 'FirewallPolicyFilterRuleCollection'
        action: { type: 'Allow' }
        rules: [
          {
            name: 'AuthenticationAndPortal'
            ruleType: 'ApplicationRule'
            sourceAddresses: [config.network.jumpboxSubnetPrefix]
            protocols: [{ protocolType: 'Https', port: 443 }]
            targetFqdns: union(identityFqdns, portalFqdns, config.hub.additionalJumpboxFqdns)
            terminateTLS: false
          }
          {
            name: 'WindowsUpdates'
            ruleType: 'ApplicationRule'
            sourceAddresses: [config.network.jumpboxSubnetPrefix]
            protocols: [
              { protocolType: 'Http', port: 80 }
              { protocolType: 'Https', port: 443 }
            ]
            fqdnTags: ['WindowsUpdate']
            terminateTLS: false
          }
          {
            name: 'CertificateRevocation'
            ruleType: 'ApplicationRule'
            sourceAddresses: [config.network.jumpboxSubnetPrefix]
            protocols: [{ protocolType: 'Http', port: 80 }]
            targetFqdns: ['crl.microsoft.com', 'mscrl.microsoft.com', 'ocsp.msocsp.com', 'www.microsoft.com']
            terminateTLS: false
          }
        ]
      }
      {
        name: 'AgentPlatform'
        priority: 300
        ruleCollectionType: 'FirewallPolicyFilterRuleCollection'
        action: { type: 'Allow' }
        rules: [
          {
            name: 'RequiredPlatformHttps'
            ruleType: 'ApplicationRule'
            sourceAddresses: [config.network.agentSubnetPrefix]
            protocols: [{ protocolType: 'Https', port: 443 }]
            targetFqdns: union(identityFqdns, platformFqdns, config.hub.additionalAgentFqdns)
            terminateTLS: false
          }
        ]
      }
    ]
  }
}

resource ip 'Microsoft.Network/publicIPAddresses@2024-05-01' = {
  name: 'pip-${names.firewall}'
  location: config.location
  tags: tags
  sku: { name: 'Standard' }
  properties: { publicIPAllocationMethod: 'Static' }
}

resource firewall 'Microsoft.Network/azureFirewalls@2024-05-01' = {
  name: names.firewall
  location: config.location
  tags: tags
  properties: {
    sku: { name: 'AZFW_VNet', tier: config.hub.firewallSku }
    firewallPolicy: { id: policy.id }
    ipConfigurations: [
      {
        name: 'firewall-ip'
        properties: {
          subnet: { id: firewallSubnetId }
          publicIPAddress: { id: ip.id }
        }
      }
    ]
  }
  dependsOn: [rules]
}

output privateIp string = firewall.properties.ipConfigurations[0].properties.privateIPAddress
