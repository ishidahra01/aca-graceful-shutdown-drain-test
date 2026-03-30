targetScope = 'resourceGroup'

@description('Short prefix used for resource names.')
param prefix string

@description('Fully qualified container image name.')
param imageName string

@description('SIGTERM to SIGKILL grace period in seconds. Microsoft documentation currently allows up to 600 seconds.')
@minValue(1)
@maxValue(600)
param terminationGracePeriodSeconds int = 30

@description('If true, SIGTERM flips the readiness endpoint to unhealthy.')
param drainReadinessOnSigterm bool = true

@description('Single or Multiple revision mode.')
@allowed([
  'Single'
  'Multiple'
])
param revisionMode string = 'Single'

@description('Container port used by the Node.js app.')
param targetPort int = 8080

@description('Minimum number of replicas.')
param minReplicas int = 1

@description('Maximum number of replicas.')
param maxReplicas int = 5

@description('HTTP concurrent request threshold used by the http KEDA scaler.')
param concurrentRequests int = 5

@description('Application Gateway backend request timeout in seconds.')
param appGatewayRequestTimeout int = 120

@description('Internal ACA default domain, obtained after bootstrap deployment.')
param privateDnsZoneName string

@description('Internal ACA static IP, obtained after bootstrap deployment.')
param managedEnvironmentStaticIp string

var acrName = take('${toLower(replace(prefix, '-', ''))}${uniqueString(resourceGroup().id)}', 50)
var managedEnvironmentName = '${prefix}-aca-env'
var virtualNetworkName = '${prefix}-vnet'
var appGatewaySubnetName = 'appgateway'
var containerAppName = '${prefix}-app'
var applicationGatewayName = '${prefix}-agw'
var publicIpName = '${prefix}-agw-pip'
var appGatewayFrontendIpName = 'publicFrontend'
var appGatewayFrontendPortName = 'httpPort'
var appGatewayBackendPoolName = 'acaPool'
var appGatewayBackendSettingsName = 'acaHttps'
var appGatewayListenerName = 'httpListener'
var appGatewayRoutingRuleName = 'httpRule'
var appGatewayProbeName = 'aca-ready'

resource acr 'Microsoft.ContainerRegistry/registries@2023-07-01' existing = {
  name: acrName
}

resource managedEnvironment 'Microsoft.App/managedEnvironments@2024-03-01' existing = {
  name: managedEnvironmentName
}

resource virtualNetwork 'Microsoft.Network/virtualNetworks@2023-11-01' existing = {
  name: virtualNetworkName
}

resource appGatewaySubnet 'Microsoft.Network/virtualNetworks/subnets@2023-11-01' existing = {
  parent: virtualNetwork
  name: appGatewaySubnetName
}

var acrPullRoleDefinitionId = subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '7f951dda-4ed3-4680-a7ca-43fe172d538d')

resource acrPullIdentity 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: '${containerAppName}-id'
  location: resourceGroup().location
}

resource acrPullRoleAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(acr.id, acrPullIdentity.id, 'acrpull')
  scope: acr
  properties: {
    principalId: acrPullIdentity.properties.principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: acrPullRoleDefinitionId
  }
}

resource containerApp 'Microsoft.App/containerApps@2024-03-01' = {
  name: containerAppName
  location: resourceGroup().location
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: {
      '${acrPullIdentity.id}': {}
    }
  }
  properties: {
    managedEnvironmentId: managedEnvironment.id
    configuration: {
      activeRevisionsMode: revisionMode
      ingress: {
        external: true
        targetPort: targetPort
        transport: 'auto'
      }
      registries: [
        {
          server: acr.properties.loginServer
          identity: acrPullIdentity.id
        }
      ]
    }
    template: {
      terminationGracePeriodSeconds: terminationGracePeriodSeconds
      containers: [
        {
          name: 'app'
          image: imageName
          resources: {
            cpu: json('0.25')
            memory: '0.5Gi'
          }
          env: [
            {
              name: 'PORT'
              value: string(targetPort)
            }
            {
              name: 'DRAIN_READINESS_ON_SIGTERM'
              value: string(drainReadinessOnSigterm)
            }
            {
              name: 'REJECT_NEW_REQUESTS_ON_DRAIN'
              value: string(drainReadinessOnSigterm)
            }
            {
              name: 'EXIT_ON_IDLE_AFTER_SIGNAL'
              value: 'true'
            }
          ]
          probes: [
            {
              type: 'Liveness'
              httpGet: {
                path: '/health/live'
                port: targetPort
                scheme: 'HTTP'
              }
              initialDelaySeconds: 5
              periodSeconds: 10
              timeoutSeconds: 2
              failureThreshold: 3
            }
            {
              type: 'Readiness'
              httpGet: {
                path: '/health/ready'
                port: targetPort
                scheme: 'HTTP'
              }
              initialDelaySeconds: 3
              periodSeconds: 5
              timeoutSeconds: 2
              failureThreshold: 1
            }
          ]
        }
      ]
      scale: {
        minReplicas: minReplicas
        maxReplicas: maxReplicas
        rules: [
          {
            name: 'http-scaler'
            custom: {
              type: 'http'
              metadata: {
                concurrentRequests: string(concurrentRequests)
              }
            }
          }
        ]
      }
    }
  }
  dependsOn: [
    acrPullRoleAssignment
  ]
}

resource privateDnsZone 'Microsoft.Network/privateDnsZones@2020-06-01' = {
  name: privateDnsZoneName
  location: 'global'
}

resource privateDnsZoneVirtualNetworkLink 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2020-06-01' = {
  parent: privateDnsZone
  name: '${prefix}-vnet-link'
  location: 'global'
  properties: {
    registrationEnabled: false
    virtualNetwork: {
      id: virtualNetwork.id
    }
  }
}

resource wildcardRecord 'Microsoft.Network/privateDnsZones/A@2020-06-01' = {
  parent: privateDnsZone
  name: '*'
  properties: {
    ttl: 30
    aRecords: [
      {
        ipv4Address: managedEnvironmentStaticIp
      }
    ]
  }
}

resource apexRecord 'Microsoft.Network/privateDnsZones/A@2020-06-01' = {
  parent: privateDnsZone
  name: '@'
  properties: {
    ttl: 30
    aRecords: [
      {
        ipv4Address: managedEnvironmentStaticIp
      }
    ]
  }
}

resource publicIp 'Microsoft.Network/publicIPAddresses@2023-11-01' = {
  name: publicIpName
  location: resourceGroup().location
  sku: {
    name: 'Standard'
  }
  properties: {
    publicIPAllocationMethod: 'Static'
  }
}

resource applicationGateway 'Microsoft.Network/applicationGateways@2024-10-01' = {
  name: applicationGatewayName
  location: resourceGroup().location
  properties: {
    sku: {
      name: 'Standard_v2'
      tier: 'Standard_v2'
      capacity: 1
    }
    gatewayIPConfigurations: [
      {
        name: 'gatewayIpConfiguration'
        properties: {
          subnet: {
            id: appGatewaySubnet.id
          }
        }
      }
    ]
    frontendIPConfigurations: [
      {
        name: appGatewayFrontendIpName
        properties: {
          publicIPAddress: {
            id: publicIp.id
          }
        }
      }
    ]
    frontendPorts: [
      {
        name: appGatewayFrontendPortName
        properties: {
          port: 80
        }
      }
    ]
    backendAddressPools: [
      {
        name: appGatewayBackendPoolName
        properties: {
          backendAddresses: [
            {
              fqdn: containerApp.properties.configuration.ingress.fqdn
            }
          ]
        }
      }
    ]
    probes: [
      {
        name: appGatewayProbeName
        properties: {
          protocol: 'Https'
          path: '/health/ready'
          interval: 10
          timeout: 5
          unhealthyThreshold: 2
          pickHostNameFromBackendHttpSettings: true
          match: {
            statusCodes: [
              '200-399'
            ]
          }
        }
      }
    ]
    backendHttpSettingsCollection: [
      {
        name: appGatewayBackendSettingsName
        properties: {
          port: 443
          protocol: 'Https'
          cookieBasedAffinity: 'Disabled'
          pickHostNameFromBackendAddress: true
          probe: {
            id: resourceId('Microsoft.Network/applicationGateways/probes', applicationGatewayName, appGatewayProbeName)
          }
          requestTimeout: appGatewayRequestTimeout
        }
      }
    ]
    httpListeners: [
      {
        name: appGatewayListenerName
        properties: {
          frontendIPConfiguration: {
            id: resourceId('Microsoft.Network/applicationGateways/frontendIPConfigurations', applicationGatewayName, appGatewayFrontendIpName)
          }
          frontendPort: {
            id: resourceId('Microsoft.Network/applicationGateways/frontendPorts', applicationGatewayName, appGatewayFrontendPortName)
          }
          protocol: 'Http'
        }
      }
    ]
    requestRoutingRules: [
      {
        name: appGatewayRoutingRuleName
        properties: {
          ruleType: 'Basic'
          priority: 100
          httpListener: {
            id: resourceId('Microsoft.Network/applicationGateways/httpListeners', applicationGatewayName, appGatewayListenerName)
          }
          backendAddressPool: {
            id: resourceId('Microsoft.Network/applicationGateways/backendAddressPools', applicationGatewayName, appGatewayBackendPoolName)
          }
          backendHttpSettings: {
            id: resourceId('Microsoft.Network/applicationGateways/backendHttpSettingsCollection', applicationGatewayName, appGatewayBackendSettingsName)
          }
        }
      }
    ]
  }
  dependsOn: [
    privateDnsZoneVirtualNetworkLink
    wildcardRecord
    apexRecord
    acrPullRoleAssignment
  ]
}

output containerAppName string = containerApp.name
output containerAppFqdn string = containerApp.properties.configuration.ingress.fqdn
output applicationGatewayName string = applicationGateway.name
output applicationGatewayPublicIp string = publicIp.properties.ipAddress
output applicationGatewayUrl string = 'http://${publicIp.properties.ipAddress}'
output managedEnvironmentDefaultDomain string = privateDnsZoneName
output managedEnvironmentStaticIp string = managedEnvironmentStaticIp
