# AMA + Prometheus: Slurm Metrics on Azure Monitor

End-to-end reference for scraping Slurm and node-exporter metrics via Azure Monitor Agent (AMA) into an Azure Monitor workspace (Managed Prometheus).

## Architecture

```
VM (Ubuntu 22.04)
  ├── prometheus-node-exporter  :9100/metrics   (system metrics)
  ├── prometheus-slurm-exporter :9092/metrics   (slurm metrics via CLI)
  └── AzureMonitorLinuxAgent
        └── azureotelcollector
              reads DCR scrape config
              scrapes :9100 + :9092
              forwards to Azure Monitor workspace
                    │
                    ▼
          Microsoft.Monitor/accounts  (Managed Prometheus)
                    │
                    ▼
          Prometheus explorer / Grafana / PromQL API
```

## Key Files

| File | Purpose |
|------|---------|
| `deploy/main.bicep` | Full self-contained deployment: workspace, DCE, DCR, VM, AMA extension, DCR association, CustomScript |
| `deploy/setup.sh` | VM bootstrap: installs node-exporter, munge, slurmctld, prometheus-slurm-exporter; validates endpoints |
| `dcr-fixed.json` | Standalone DCR-only bicep (for attaching to existing VMs) |
| `bicep-fixed.json` | Standalone VM bicep that accepts a pre-existing DCR ID |

## Bugs Found and Fixes Applied

### 1. `customVMScrapeConfig` silently dropped (wrong API version)

The DCR resource must use `api-version=2024-03-11`. Older versions (`2022-06-01`, `2023-03-11`) accept the property without error but silently discard it, so AMA receives no scrape configuration.

```bicep
// WRONG - silently drops customVMScrapeConfig
resource dcr 'Microsoft.Insights/dataCollectionRules@2022-06-01' = { ... }

// CORRECT
resource dcr 'Microsoft.Insights/dataCollectionRules@2024-03-11' = { ... }
```

Bicep emits a `BCP037` warning on `customVMScrapeConfig` (undocumented property). Suppress with:
```bicep
#disable-next-line BCP037
customVMScrapeConfig: { ... }
```

### 2. Missing DCR association

A DCR must be explicitly associated with each VM. Without a `dataCollectionRuleAssociations` resource, AMA ignores the DCR entirely and scrapes nothing.

```bicep
resource dcrAssociation 'Microsoft.Insights/dataCollectionRuleAssociations@2022-06-01' = {
  name: '${vmName}-slurm-dcra'
  scope: vm
  dependsOn: [amaExtension]
  properties: {
    dataCollectionRuleId: dcr.id
  }
}
```

### 3. `GCS_AUTO_CONFIG: true` overrides DCR config

Setting this flag in the AMA extension routes configuration through Microsoft's internal Geneva Configuration Service, which overrides any DCR-based scrape config. The flag must be absent (or the `settings` block must be empty).

```bicep
// WRONG - GCS overrides DCR scrape config
settings: {
  GCS_AUTO_CONFIG: 'true'
}

// CORRECT - empty settings, DCR config takes effect
settings: {}
```

### 4. Slurm native `MetricsType=metrics/openmetrics` requires Slurm >= 22.05

Ubuntu 22.04 ships Slurm 21.08, which predates the openmetrics plugin. Adding `MetricsType=metrics/openmetrics` to `slurm.conf` causes `slurmctld` to fail to start with a parsing error.

Fix: use [rivosinc/prometheus-slurm-exporter](https://github.com/rivosinc/prometheus-slurm-exporter) as a sidecar. It polls Slurm CLI tools and exposes all metrics at `:9092/metrics`, compatible with Slurm 21.x+.

### 5. `dpkg` lock contention on first boot

Cloud-init and unattended-upgrades hold the dpkg lock on startup. `apt-get` fails immediately without a wait loop.

```bash
while fuser /var/lib/dpkg/lock-frontend /var/lib/apt/lists/lock >/dev/null 2>&1; do
  sleep 5
done
```

### 6. `munge` apt package pre-creates a key

`apt-get install munge` automatically creates `/etc/munge/munge.key`. Running `mungekey --create` unconditionally fails with "File exists". Fixed with a guard:

```bash
if [ ! -f /etc/munge/munge.key ]; then
  mungekey --create --keyfile /etc/munge/munge.key
fi
```

## Deployment

```bash
# Create resource group
az group create -n jesse-test-ama -l eastus \
  --subscription 75d1e0d5-9fed-4ae1-aec7-2ecc19de26fa

# Deploy everything
az deployment group create \
  --resource-group jesse-test-ama \
  --template-file deploy/main.bicep \
  --parameters sshPublicKey="$(cat ~/.ssh/id_ed25519.pub)"

# Get VM public IP
az deployment group show \
  --resource-group jesse-test-ama \
  --name main \
  --query properties.outputs.publicIp.value -o tsv
```

## Verifying Metrics

Query the workspace Prometheus API directly:

```bash
TOKEN=$(az account get-access-token \
  --resource https://prometheus.monitor.azure.com \
  --query accessToken -o tsv)

ENDPOINT="https://jesse-ama-ws-fzaffzf2c6b6h0ds.eastus.prometheus.monitor.azure.com"

# List all metric names
curl -s -H "Authorization: Bearer $TOKEN" \
  "$ENDPOINT/api/v1/label/__name__/values" | jq '.data | length'

# Query Slurm CPU count
curl -s -H "Authorization: Bearer $TOKEN" \
  "$ENDPOINT/api/v1/query?query=slurm_cpus_total" | jq .

# Query node state
curl -s -H "Authorization: Bearer $TOKEN" \
  "$ENDPOINT/api/v1/query?query=slurm_node_count_per_state" | jq .
```

Or use the Prometheus explorer in the Azure portal:
`portal.azure.com > jesse-ama-ws > Managed Prometheus > Prometheus explorer`

## Results

330 total metrics confirmed flowing (16 `slurm_*`, 253 `node_*`, remainder standard Go/process metrics).

See `screenshots/` for portal evidence.
