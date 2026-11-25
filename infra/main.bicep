targetScope = 'subscription'

import { Configuration } from './types.bicep'

@description('Deploy hub, private foundation, Foundry account/project, then container-scoped runtime access.')
@allowed([
  'hub'
  'foundation'
  'foundry'
  'access'
])
param stage string

@description('Nonsecret settings. Subscription and tenant are taken from the active deployment context.')
param config Configuration = loadJsonContent('./config.default.json')

@description('Interactive Entra user object ID, resolved at runtime by Deploy.ps1. Never a client/application ID.')
@minLength(36)
@maxLength(36)
param userObjectId string

@secure()
@description('Windows bootstrap password, required only for the hub stage. Never written to outputs.')
param adminPassword string = ''

@description('Foundry-created file container name, discovered at runtime for the access stage.')
param blobContainerName string = ''

@description('Foundry-created agent container name, discovered at runtime for the access stage.')
param agentContainerName string = ''

@description('Project managed identity object ID, discovered at runtime for the access stage.')
param projectPrincipalId string = ''

var stem = '${config.workloadName}-${config.nameSuffix}'
var token = take(uniqueString(subscription().id, stem), 6)
var names = union({
  hubResourceGroup: 'rg-${stem}-hub'
  spokeResourceGroup: 'rg-${stem}-spoke'
  hubVnet: 'vnet-${stem}-hub'
  spokeVnet: 'vnet-${stem}-spoke'
  bastion: 'bas-${stem}'
  firewall: 'afw-${stem}'
  firewallPolicy: 'afwp-${stem}'
  jumpbox: 'vm-${stem}'
  storage: 'st${config.workloadName}${config.nameSuffix}${token}'
  cosmos: 'cosmos-${stem}-${token}'
  search: 'srch-${stem}-${token}'
  keyVault: 'kv-${stem}-${token}'
  foundry: 'ai-${stem}-${token}'
  logAnalytics: 'log-${stem}'
  appInsights: 'appi-${stem}'
  monitorScope: 'ampls-${stem}'
}, config.resourceNames)
var tags = union(config.tags, { deploymentSuffix: config.nameSuffix })

resource hubRg 'Microsoft.Resources/resourceGroups@2024-03-01' = {
  name: names.hubResourceGroup
  location: config.location
  tags: tags
}

resource spokeRg 'Microsoft.Resources/resourceGroups@2024-03-01' = {
  name: names.spokeResourceGroup
  location: config.location
  tags: tags
}

module hub './modules/hub.bicep' = if (stage == 'hub') {
  name: 'hub-infrastructure'
  scope: hubRg
  params: {
    config: config
    names: names
    tags: tags
    userObjectId: userObjectId
    adminPassword: adminPassword
  }
}

module foundation './modules/foundation.bicep' = if (stage == 'foundation') {
  name: 'spoke-foundation'
  scope: spokeRg
  params: {
    config: config
    names: names
    tags: tags
    userObjectId: userObjectId
    hubResourceGroupName: hubRg.name
  }
}

module hubPeering './modules/peering.bicep' = if (stage == 'foundation') {
  name: 'hub-to-spoke-peering'
  scope: hubRg
  params: {
    localVnetName: names.hubVnet
    remoteVnetId: foundation!.outputs.spokeVnetId
    peeringName: 'hub-to-spoke'
  }
}

module hubDiagnostics './modules/hub-diagnostics.bicep' = if (stage == 'foundation') {
  name: 'hub-diagnostics'
  scope: hubRg
  params: {
    firewallName: names.firewall
    bastionName: names.bastion
    workspaceId: foundation!.outputs.workspaceId
  }
}

module foundry './modules/foundry.bicep' = if (stage == 'foundry') {
  name: 'foundry-account-project'
  scope: spokeRg
  params: {
    config: config
    names: names
    tags: tags
  }
}

module runtime './modules/runtime-access.bicep' = if (stage == 'access') {
  name: 'project-runtime-access'
  scope: spokeRg
  params: {
    names: names
    projectName: config.projectName
    userObjectId: userObjectId
    blobContainerName: blobContainerName
    agentContainerName: agentContainerName
    projectPrincipalId: projectPrincipalId
  }
}

output resourceNames object = names
output projectName string = config.projectName
output projectEndpoint string = 'https://${names.foundry}.services.ai.azure.com/api/projects/${config.projectName}'
output modelEndpoint string = 'https://${names.foundry}.openai.azure.com/'
output deploymentStage string = stage
