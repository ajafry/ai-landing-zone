import { Configuration } from '../types.bicep'

param config Configuration
param name string
param tags object
param subnetId string
param userObjectId string
param dnsServerIp string
@secure()
param adminPassword string

resource nic 'Microsoft.Network/networkInterfaces@2024-05-01' = {
  name: 'nic-${name}'
  location: config.location
  tags: tags
  properties: {
    enableIPForwarding: false
    dnsSettings: { dnsServers: [dnsServerIp] }
    ipConfigurations: [
      {
        name: 'private'
        properties: {
          subnet: { id: subnetId }
          privateIPAllocationMethod: 'Dynamic'
        }
      }
    ]
  }
}

resource vm 'Microsoft.Compute/virtualMachines@2024-07-01' = {
  name: name
  location: config.location
  tags: tags
  identity: { type: 'SystemAssigned' }
  properties: {
    hardwareProfile: { vmSize: config.vm.size }
    licenseType: config.vm.licenseType
    securityProfile: union({
      securityType: config.vm.securityType
    }, config.vm.securityType == 'TrustedLaunch' ? {
      uefiSettings: { secureBootEnabled: true, vTpmEnabled: true }
    } : {})
    storageProfile: {
      imageReference: {
        publisher: config.vm.imagePublisher
        offer: config.vm.imageOffer
        sku: config.vm.imageSku
        version: config.vm.imageVersion
      }
      osDisk: {
        createOption: 'FromImage'
        diskSizeGB: config.vm.osDiskSizeGB
        managedDisk: { storageAccountType: config.vm.osDiskSku }
        deleteOption: 'Delete'
      }
    }
    osProfile: {
      computerName: take(replace(name, '-', ''), 15)
      adminUsername: config.vm.adminUsername
      adminPassword: adminPassword
      windowsConfiguration: {
        provisionVMAgent: true
        enableAutomaticUpdates: true
        patchSettings: { patchMode: 'AutomaticByOS' }
      }
    }
    networkProfile: {
      networkInterfaces: [
        {
          id: nic.id
          properties: { primary: true, deleteOption: 'Delete' }
        }
      ]
    }
    diagnosticsProfile: { bootDiagnostics: { enabled: false } }
  }
}

resource loginExtension 'Microsoft.Compute/virtualMachines/extensions@2024-07-01' = {
  parent: vm
  name: 'AADLoginForWindows'
  location: config.location
  properties: {
    publisher: 'Microsoft.Azure.ActiveDirectory'
    type: 'AADLoginForWindows'
    typeHandlerVersion: '1.0'
    autoUpgradeMinorVersion: true
  }
}

resource vmAdmin 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: vm
  name: guid(vm.id, userObjectId, 'vm-admin-login')
  properties: {
    principalId: userObjectId
    principalType: 'User'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '1c0163c0-47e6-4577-8991-ea5c82e286e4')
  }
}
