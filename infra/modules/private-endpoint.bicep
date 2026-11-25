param location string
param name string
param tags object
param subnetId string
param resourceId string
param groupId string
param dnsZoneIds string[]

resource endpoint 'Microsoft.Network/privateEndpoints@2024-05-01' = {
  name: name
  location: location
  tags: tags
  properties: {
    subnet: { id: subnetId }
    privateLinkServiceConnections: [
      {
        name: '${name}-connection'
        properties: {
          privateLinkServiceId: resourceId
          groupIds: [groupId]
        }
      }
    ]
  }
}

resource zoneGroup 'Microsoft.Network/privateEndpoints/privateDnsZoneGroups@2024-05-01' = {
  parent: endpoint
  name: 'default'
  properties: {
    privateDnsZoneConfigs: [for (zoneId, index) in dnsZoneIds: {
      name: 'zone-${index}'
      properties: { privateDnsZoneId: zoneId }
    }]
  }
}

output id string = endpoint.id
