param hubVnetId string
param spokeVnetId string
param tags object

var zoneNames = [
  'privatelink.cognitiveservices.azure.com'
  'privatelink.openai.azure.com'
  'privatelink.services.ai.azure.com'
  'privatelink.blob.${environment().suffixes.storage}'
  'privatelink.documents.azure.com'
  'privatelink.search.windows.net'
  'privatelink.vaultcore.azure.net'
  'privatelink.monitor.azure.com'
  'privatelink.oms.opinsights.azure.com'
  'privatelink.ods.opinsights.azure.com'
  'privatelink.agentsvc.azure-automation.net'
]

resource zones 'Microsoft.Network/privateDnsZones@2024-06-01' = [for zoneName in zoneNames: {
  name: zoneName
  location: 'global'
  tags: tags
}]

resource hubLinks 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2024-06-01' = [for (zoneName, index) in zoneNames: {
  parent: zones[index]
  name: 'hub'
  location: 'global'
  properties: {
    registrationEnabled: false
    virtualNetwork: { id: hubVnetId }
  }
}]

resource spokeLinks 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2024-06-01' = [for (zoneName, index) in zoneNames: {
  parent: zones[index]
  name: 'spoke'
  location: 'global'
  properties: {
    registrationEnabled: false
    virtualNetwork: { id: spokeVnetId }
  }
}]

output zoneIds object = toObject(zoneNames, zoneName => zoneName, zoneName => resourceId('Microsoft.Network/privateDnsZones', zoneName))
