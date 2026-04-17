targetScope = 'resourceGroup'

param location string = 'eastus'
param adminUsername string = 'azladmin'
param vmName string = 'jesse-ama-test'
param vmSize string = 'Standard_D4ads_v5'
param sshPublicKey string

// ── Monitor workspace ──────────────────────────────────────────────────────
resource monitorWorkspace 'Microsoft.Monitor/accounts@2023-04-03' = {
  name: 'jesse-ama-ws'
  location: location
}

// ── Data Collection Endpoint ───────────────────────────────────────────────
resource dce 'Microsoft.Insights/dataCollectionEndpoints@2022-06-01' = {
  name: 'jesse-ama-dce'
  location: location
  properties: {
    networkAcls: {
      publicNetworkAccess: 'Enabled'
    }
  }
}

// ── Data Collection Rule ───────────────────────────────────────────────────
resource dcr 'Microsoft.Insights/dataCollectionRules@2024-03-11' = {
  name: 'jesse-slurm-dcr'
  location: location
  properties: {
    dataCollectionEndpointId: dce.id
    dataSources: {
      prometheusForwarder: [
        {
          name: 'Slurm-OpenMetrics'
          streams: ['Microsoft-PrometheusMetrics']
          #disable-next-line BCP037
          customVMScrapeConfig: {
            scrape_configs: [
              // node-exporter: system-level metrics
              {
                job_name: 'node-exporter'
                scrape_interval: '30s'
                metrics_path: '/metrics'
                scheme: 'http'
                static_configs: [
                  {
                    targets: ['127.0.0.1:9100']
                  }
                ]
              }
              // Slurm native openmetrics plugin (MetricsType=metrics/openmetrics,
              // introduced in Slurm 25.11). slurmctld serves 5 sub-endpoints on
              // its RPC port (6817). 60s interval per SchedMD guidance (shorter
              // intervals cause slurmctld lock contention).
              {
                job_name: 'slurm-jobs'
                scrape_interval: '60s'
                metrics_path: '/metrics/jobs'
                scheme: 'http'
                static_configs: [{ targets: ['127.0.0.1:6817'] }]
              }
              {
                job_name: 'slurm-jobs-users-accts'
                scrape_interval: '60s'
                metrics_path: '/metrics/jobs-users-accts'
                scheme: 'http'
                static_configs: [{ targets: ['127.0.0.1:6817'] }]
              }
              {
                job_name: 'slurm-nodes'
                scrape_interval: '60s'
                metrics_path: '/metrics/nodes'
                scheme: 'http'
                static_configs: [{ targets: ['127.0.0.1:6817'] }]
              }
              {
                job_name: 'slurm-partitions'
                scrape_interval: '60s'
                metrics_path: '/metrics/partitions'
                scheme: 'http'
                static_configs: [{ targets: ['127.0.0.1:6817'] }]
              }
              {
                job_name: 'slurm-scheduler'
                scrape_interval: '60s'
                metrics_path: '/metrics/scheduler'
                scheme: 'http'
                static_configs: [{ targets: ['127.0.0.1:6817'] }]
              }
            ]
          }
        }
      ]
    }
    destinations: {
      monitoringAccounts: [
        {
          accountResourceId: monitorWorkspace.id
          name: 'MonitoringAccountDestination'
        }
      ]
    }
    dataFlows: [
      {
        streams: ['Microsoft-PrometheusMetrics']
        destinations: ['MonitoringAccountDestination']
      }
    ]
  }
}

// ── Networking ─────────────────────────────────────────────────────────────
resource vnet 'Microsoft.Network/virtualNetworks@2023-09-01' = {
  name: 'jesse-ama-vnet'
  location: location
  properties: {
    addressSpace: {
      addressPrefixes: ['10.0.0.0/16']
    }
    subnets: [
      {
        name: 'default'
        properties: {
          addressPrefix: '10.0.0.0/24'
        }
      }
    ]
  }
}

resource nsg 'Microsoft.Network/networkSecurityGroups@2023-09-01' = {
  name: 'jesse-ama-nsg'
  location: location
  properties: {
    securityRules: [
      {
        name: 'allow-ssh'
        properties: {
          priority: 1000
          protocol: 'Tcp'
          access: 'Allow'
          direction: 'Inbound'
          sourceAddressPrefix: '*'
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
          destinationPortRange: '22'
        }
      }
    ]
  }
}

resource pip 'Microsoft.Network/publicIPAddresses@2023-09-01' = {
  name: '${vmName}-pip'
  location: location
  sku: {
    name: 'Standard'
  }
  properties: {
    publicIPAllocationMethod: 'Static'
  }
}

resource nic 'Microsoft.Network/networkInterfaces@2023-09-01' = {
  name: '${vmName}-nic'
  location: location
  properties: {
    networkSecurityGroup: {
      id: nsg.id
    }
    ipConfigurations: [
      {
        name: 'ipconfig'
        properties: {
          privateIPAllocationMethod: 'Dynamic'
          publicIPAddress: {
            id: pip.id
          }
          subnet: {
            id: vnet.properties.subnets[0].id
          }
        }
      }
    ]
  }
}

// ── Virtual Machine ────────────────────────────────────────────────────────
resource vm 'Microsoft.Compute/virtualMachines@2023-09-01' = {
  name: vmName
  location: location
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    osProfile: {
      computerName: vmName
      adminUsername: adminUsername
      linuxConfiguration: {
        disablePasswordAuthentication: true
        patchSettings: {
          patchMode: 'ImageDefault'
        }
        ssh: {
          publicKeys: [
            {
              path: '/home/${adminUsername}/.ssh/authorized_keys'
              keyData: sshPublicKey
            }
          ]
        }
      }
    }
    hardwareProfile: {
      vmSize: vmSize
    }
    storageProfile: {
      imageReference: {
        publisher: 'Canonical'
        offer: 'ubuntu-24_04-lts'
        sku: 'server'
        version: 'latest'
      }
      osDisk: {
        name: '${vmName}-os'
        createOption: 'FromImage'
        managedDisk: {
          storageAccountType: 'StandardSSD_LRS'
        }
        deleteOption: 'Delete'
      }
    }
    networkProfile: {
      networkInterfaces: [
        {
          id: nic.id
          properties: {
            deleteOption: 'Delete'
            primary: true
          }
        }
      ]
    }
    diagnosticsProfile: {
      bootDiagnostics: {
        enabled: true
      }
    }
  }
}

// ── Azure Monitor Agent extension ──────────────────────────────────────────
// GCS_AUTO_CONFIG intentionally omitted: it routes config through
// Microsoft-internal Geneva Configuration Service and overrides DCR config.
resource amaExtension 'Microsoft.Compute/virtualMachines/extensions@2023-09-01' = {
  parent: vm
  name: 'AzureMonitorLinuxAgent'
  location: location
  properties: {
    autoUpgradeMinorVersion: true
    enableAutomaticUpgrade: true
    publisher: 'Microsoft.Azure.Monitor'
    type: 'AzureMonitorLinuxAgent'
    typeHandlerVersion: '1.0'
    settings: {}
  }
}

// ── DCR association: wires the VM to the DCR ───────────────────────────────
// Without this AMA has no config and scrapes nothing.
resource dcrAssociation 'Microsoft.Insights/dataCollectionRuleAssociations@2022-06-01' = {
  name: '${vmName}-slurm-dcra'
  scope: vm
  dependsOn: [amaExtension]
  properties: {
    description: 'Associate Slurm DCR with ${vmName}'
    dataCollectionRuleId: dcr.id
  }
}

// ── cloud-init: install slurm, node-exporter, wire everything up ───────────
resource vmSetup 'Microsoft.Compute/virtualMachines/extensions@2023-09-01' = {
  parent: vm
  name: 'CustomScript'
  location: location
  dependsOn: [amaExtension]
  properties: {
    publisher: 'Microsoft.Azure.Extensions'
    type: 'CustomScript'
    typeHandlerVersion: '2.1'
    autoUpgradeMinorVersion: true
    settings: {
      script: loadFileAsBase64('setup.sh')
    }
  }
}

// ── Outputs ────────────────────────────────────────────────────────────────
output publicIp string = pip.properties.ipAddress
output vmResourceId string = vm.id
output dcrId string = dcr.id
output monitorWorkspaceId string = monitorWorkspace.id
