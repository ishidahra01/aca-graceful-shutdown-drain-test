targetScope = 'subscription'

@description('Azure region for all resources.')
param location string

@description('Short prefix used for resource names.')
param prefix string

@description('Resource group name to create.')
param resourceGroupName string = '${prefix}-rg'

resource resourceGroup 'Microsoft.Resources/resourceGroups@2024-03-01' = {
  name: resourceGroupName
  location: location
}

module foundation './foundation.bicep' = {
  name: 'foundation'
  scope: resourceGroup
  params: {
    location: location
    prefix: prefix
  }
}

output resourceGroupName string = resourceGroup.name
output logAnalyticsWorkspaceName string = foundation.outputs.logAnalyticsWorkspaceName
output logAnalyticsWorkspaceId string = foundation.outputs.logAnalyticsWorkspaceId
output logAnalyticsCustomerId string = foundation.outputs.logAnalyticsCustomerId
output acrName string = foundation.outputs.acrName
output acrLoginServer string = foundation.outputs.acrLoginServer
output managedEnvironmentName string = foundation.outputs.managedEnvironmentName
output managedEnvironmentDefaultDomain string = foundation.outputs.managedEnvironmentDefaultDomain
output managedEnvironmentStaticIp string = foundation.outputs.managedEnvironmentStaticIp
output virtualNetworkName string = foundation.outputs.virtualNetworkName
output appGatewaySubnetId string = foundation.outputs.appGatewaySubnetId
