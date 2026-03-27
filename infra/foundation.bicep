param location string
param prefix string

var acrName = take('${toLower(replace(prefix, '-', ''))}${uniqueString(resourceGroup().id)}', 50)
var workspaceName = '${prefix}-law'
var virtualNetworkName = '${prefix}-vnet'
var acaInfrastructureSubnetName = 'aca-infrastructure'
var appGatewaySubnetName = 'appgateway'
var managedEnvironmentName = '${prefix}-aca-env'

resource workspace 'Microsoft.OperationalInsights/workspaces@2023-09-01' = {
  name: workspaceName
  location: location
  properties: {
    retentionInDays: 30
    sku: {
      name: 'PerGB2018'
    }
  }
}

resource acr 'Microsoft.ContainerRegistry/registries@2023-07-01' = {
  name: acrName
  location: location
  sku: {
    name: 'Basic'
  }
  properties: {
    adminUserEnabled: false
    publicNetworkAccess: 'Enabled'
  }
}

resource virtualNetwork 'Microsoft.Network/virtualNetworks@2023-11-01' = {
  name: virtualNetworkName
  location: location
  properties: {
    addressSpace: {
      addressPrefixes: [
        '10.10.0.0/16'
      ]
    }
    subnets: [
      {
        name: acaInfrastructureSubnetName
        properties: {
          addressPrefix: '10.10.0.0/23'
          delegations: [
            {
              name: 'acaDelegation'
              properties: {
                serviceName: 'Microsoft.App/environments'
              }
            }
          ]
        }
      }
      {
        name: appGatewaySubnetName
        properties: {
          addressPrefix: '10.10.2.0/24'
        }
      }
    ]
  }
}

resource acaInfrastructureSubnet 'Microsoft.Network/virtualNetworks/subnets@2023-11-01' existing = {
  parent: virtualNetwork
  name: acaInfrastructureSubnetName
}

resource managedEnvironment 'Microsoft.App/managedEnvironments@2024-03-01' = {
  name: managedEnvironmentName
  location: location
  properties: {
    appLogsConfiguration: {
      destination: 'log-analytics'
      logAnalyticsConfiguration: {
        customerId: workspace.properties.customerId
        sharedKey: workspace.listKeys().primarySharedKey
      }
    }
    vnetConfiguration: {
      infrastructureSubnetId: acaInfrastructureSubnet.id
      internal: true
    }
  }
}

output logAnalyticsWorkspaceName string = workspace.name
output logAnalyticsWorkspaceId string = workspace.id
output logAnalyticsCustomerId string = workspace.properties.customerId
output acrName string = acr.name
output acrLoginServer string = acr.properties.loginServer
output managedEnvironmentName string = managedEnvironment.name
output managedEnvironmentDefaultDomain string = managedEnvironment.properties.defaultDomain
output managedEnvironmentStaticIp string = managedEnvironment.properties.staticIp
output virtualNetworkName string = virtualNetwork.name
output appGatewaySubnetId string = resourceId('Microsoft.Network/virtualNetworks/subnets', virtualNetwork.name, appGatewaySubnetName)
