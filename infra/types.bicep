@export()
type Configuration = {
  location: string
  @minLength(1)
  @maxLength(6)
  workloadName: string
  @minLength(1)
  @maxLength(6)
  nameSuffix: string
  @minLength(2)
  @maxLength(64)
  projectName: string
  resourceNames: { *: string }
  tags: { *: string }
  network: {
    hubAddressPrefix: string
    bastionSubnetPrefix: string
    firewallSubnetPrefix: string
    jumpboxSubnetPrefix: string
    spokeAddressPrefix: string
    agentSubnetName: string
    agentSubnetPrefix: string
    privateEndpointSubnetName: string
    privateEndpointSubnetPrefix: string
  }
  hub: {
    bastionSku: 'Standard' | 'Premium'
    firewallSku: 'Standard' | 'Premium'
    additionalJumpboxFqdns: string[]
    additionalAgentFqdns: string[]
  }
  vm: {
    size: string
    adminUsername: string
    imagePublisher: string
    imageOffer: string
    imageSku: string
    imageVersion: string
    licenseType: string
    @minValue(64)
    osDiskSizeGB: int
    osDiskSku: 'Premium_LRS' | 'StandardSSD_LRS'
    securityType: 'TrustedLaunch' | 'Standard'
  }
  services: {
    storageSku: 'Standard_LRS' | 'Standard_ZRS' | 'Standard_GRS' | 'Standard_RAGRS'
    searchSku: 'basic' | 'standard' | 'standard2' | 'standard3'
    @minValue(1)
    searchReplicas: int
    @minValue(1)
    searchPartitions: int
    @minValue(6000)
    cosmosTotalThroughputLimit: int
    keyVaultSku: 'standard' | 'premium'
    @minValue(30)
    @maxValue(730)
    logRetentionDays: int
    @minValue(1)
    logDailyQuotaGB: int
  }
  models: {
    deploymentName: string
    modelName: string
    version: string
    sku: 'GlobalStandard' | 'DataZoneStandard' | 'Standard'
    @minValue(1)
    capacity: int
  }[]
}
