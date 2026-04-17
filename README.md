# AMA + Prometheus: Slurm Metrics on Azure Monitor

End-to-end reference for scraping Slurm and node-exporter metrics via Azure Monitor Agent (AMA) into an Azure Monitor workspace (Managed Prometheus), using Slurm's **native `metrics/openmetrics` plugin** (no sidecar exporter).

## Architecture

```
VM (Ubuntu 24.04)
  ├── prometheus-node-exporter       :9100/metrics               (system metrics)
  └── slurmctld (Slurm 25.11, built from source)
        metrics/openmetrics plugin   :6817/metrics/jobs
                                     :6817/metrics/jobs-users-accts
                                     :6817/metrics/nodes
                                     :6817/metrics/partitions
                                     :6817/metrics/scheduler
  └── AzureMonitorLinuxAgent
        └── azureotelcollector
              reads DCR scrape config
              scrapes :9100 + :6817 sub-endpoints
              forwards to Azure Monitor workspace
                    │
                    ▼
          Microsoft.Monitor/accounts  (Managed Prometheus)
                    │
                    ▼
          Prometheus explorer / Grafana / PromQL API
```

The Slurm native openmetrics plugin was introduced in **Slurm 25.11**. Ubuntu 24.04 ships 23.11, so `setup.sh` builds 25.11.5 from source. `slurmctld` serves the Prometheus-format endpoints on its RPC port (6817); no separate port parameter is required.

## Key Files

| File | Purpose |
|------|---------|
| `deploy/main.bicep` | Full self-contained deployment: Monitor workspace, DCE, DCR with 5 slurm scrape jobs, VM, AMA extension, DCR association, CustomScript bootstrap |
| `deploy/setup.sh` | VM bootstrap: installs node-exporter, munge; builds Slurm 25.11.5 from source with `--with-http-parser --with-yaml --with-jwt`; writes `slurm.conf` with `MetricsType=metrics/openmetrics`; installs systemd units; submits a test job |

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
settings: { GCS_AUTO_CONFIG: 'true' }

// CORRECT - empty settings, DCR config takes effect
settings: {}
```

### 4. Slurm native openmetrics plugin requires Slurm >= 25.11

Earlier Slurm versions do not ship the `metrics/openmetrics` plugin. Ubuntu 24.04's distro Slurm is 23.11; adding `MetricsType=metrics/openmetrics` to `slurm.conf` on that version causes `slurmctld` to fail to start.

Fix: build Slurm from source. `setup.sh` pulls `slurm-25.11.5.tar.bz2` from `download.schedmd.com`, installs the build dependencies (`libhttp-parser-dev libyaml-dev libjson-c-dev libjwt-dev libmunge-dev`), runs `./configure --with-http-parser --with-yaml --with-jwt && make && make install`, and verifies `/usr/local/lib/slurm/metrics_openmetrics.so` exists before starting the service.

### 5. openmetrics is served on the RPC port, not a separate port

Do **not** set `SlurmctldParameters=enable_openmetrics,openmetrics_port=XXXX`. Those parameters do not exist. With `MetricsType=metrics/openmetrics` in `slurm.conf`, `slurmctld` serves the metrics endpoints directly on its existing RPC port (`SlurmctldPort=6817`). Scrape config must target `127.0.0.1:6817`, not a separate port.

### 6. Source install does not ship systemd units

`make install` installs the binaries but not `slurmctld.service` / `slurmd.service`. `setup.sh` writes minimal units to `/etc/systemd/system/` before `systemctl enable --now`.

### 7. `sbatch` must run from a directory writable by the slurm user

Submitting a job with `sudo -u slurm sbatch --wrap=...` from `/root` or `/home/azladmin` fails immediately: the default stdout path (`slurm-N.out`) is created in the cwd, and the slurm user can't write there, so IO setup aborts. Fix: `cd /home/slurm` first.

### 8. `dpkg` lock contention on first boot

Cloud-init and unattended-upgrades hold the dpkg lock on startup. `apt-get` fails immediately without a wait loop.

```bash
while fuser /var/lib/dpkg/lock-frontend /var/lib/apt/lists/lock >/dev/null 2>&1; do
  sleep 5
done
```

### 9. `munge` apt package pre-creates a key

`apt-get install munge` automatically creates `/etc/munge/munge.key`. Running `mungekey --create` unconditionally fails with "File exists". Guard it:

```bash
if [ ! -f /etc/munge/munge.key ]; then
  mungekey --create --keyfile /etc/munge/munge.key
fi
```

## DCR scrape configuration

`deploy/main.bicep` configures six scrape jobs: one for node-exporter and one for each of the five Slurm openmetrics sub-endpoints. 60s intervals on the Slurm endpoints per SchedMD guidance (shorter intervals can cause slurmctld lock contention).

```bicep
scrape_configs: [
  { job_name: 'node-exporter',           scrape_interval: '30s', metrics_path: '/metrics',                  static_configs: [{ targets: ['127.0.0.1:9100'] }] }
  { job_name: 'slurm-jobs',              scrape_interval: '60s', metrics_path: '/metrics/jobs',             static_configs: [{ targets: ['127.0.0.1:6817'] }] }
  { job_name: 'slurm-jobs-users-accts',  scrape_interval: '60s', metrics_path: '/metrics/jobs-users-accts', static_configs: [{ targets: ['127.0.0.1:6817'] }] }
  { job_name: 'slurm-nodes',             scrape_interval: '60s', metrics_path: '/metrics/nodes',            static_configs: [{ targets: ['127.0.0.1:6817'] }] }
  { job_name: 'slurm-partitions',        scrape_interval: '60s', metrics_path: '/metrics/partitions',       static_configs: [{ targets: ['127.0.0.1:6817'] }] }
  { job_name: 'slurm-scheduler',         scrape_interval: '60s', metrics_path: '/metrics/scheduler',        static_configs: [{ targets: ['127.0.0.1:6817'] }] }
]
```

## Deployment

```bash
az group create -n jesse-test-ama -l eastus \
  --subscription 75d1e0d5-9fed-4ae1-aec7-2ecc19de26fa

az deployment group create \
  --resource-group jesse-test-ama \
  --template-file deploy/main.bicep \
  --parameters sshPublicKey="$(cat ~/.ssh/id_ed25519.pub)"

az deployment group show \
  --resource-group jesse-test-ama \
  --name main \
  --query properties.outputs.publicIp.value -o tsv
```

`setup.sh` runs as a CustomScript extension. It takes 8-10 minutes to finish because it compiles Slurm. Watch progress on the VM:

```bash
ssh azladmin@<publicIp> 'sudo tail -f /var/log/ama-setup.log'
```

## Viewing the Metrics

### Azure Portal, Prometheus explorer

```
portal.azure.com
  -> Resource Groups -> jesse-test-ama
  -> jesse-ama-ws (Azure Monitor workspace)
  -> Managed Prometheus -> Prometheus explorer
```

Useful PromQL queries:

```promql
# collector health
up

# job-level metrics
slurm_jobs_running
slurm_jobs_pending
slurm_jobs_cpus_alloc

# per-user, per-partition
sum by (username)  (slurm_user_jobs_running)
sum by (partition) (slurm_partition_jobs_running)

# node/cluster state
slurm_nodes_idle
slurm_nodes_mixed

# ingestion freshness (seconds since last sample)
time() - timestamp(slurm_jobs_running)

# count of unique slurm_* metrics in the workspace
count(count by (__name__) ({__name__=~"slurm_.*"}))
```

### curl against the Prometheus HTTP API

```bash
TOKEN=$(az account get-access-token \
  --resource https://prometheus.monitor.azure.com \
  --query accessToken -o tsv)

ENDPOINT=$(az monitor account show -g jesse-test-ama -n jesse-ama-ws \
  -o json | python3 -c "import sys,json; print(json.load(sys.stdin)['metrics']['prometheusQueryEndpoint'])")

# instant query
curl -s -H "Authorization: Bearer $TOKEN" \
  "$ENDPOINT/api/v1/query?query=slurm_jobs_running" | jq

# list every metric name currently in the workspace
curl -s -H "Authorization: Bearer $TOKEN" \
  "$ENDPOINT/api/v1/label/__name__/values" | jq '.data | length'
```

### Grafana (Azure Managed or local)

```bash
az grafana create -g jesse-test-ama -n jesse-grafana -l eastus

GRAFANA_MI=$(az grafana show -g jesse-test-ama -n jesse-grafana --query identity.principalId -o tsv)
WS_ID=$(az monitor account show -g jesse-test-ama -n jesse-ama-ws --query id -o tsv)
az role assignment create --assignee "$GRAFANA_MI" \
  --role "Monitoring Data Reader" --scope "$WS_ID"
```

Then in Grafana, add a Prometheus data source with the workspace endpoint URL and Managed Identity authentication.

### Infrastructure verification (Resource Graph, KQL)

The Azure Monitor workspace is queried with PromQL, not KQL, because it is a Prometheus store rather than a Log Analytics workspace. KQL is still useful for verifying the surrounding infrastructure via Resource Graph:

```kusto
// DCR has prometheusForwarder + customVMScrapeConfig
resources
| where type =~ 'microsoft.insights/datacollectionrules'
| where resourceGroup =~ 'jesse-test-ama'
| project name, scrapeJobs = properties.dataSources.prometheusForwarder[0].customVMScrapeConfig.scrape_configs

// DCR association present (AMA ignores the DCR without this)
resources
| where type =~ 'microsoft.insights/datacollectionruleassociations'
| where id contains 'jesse-ama-test'
| project name, dcrId = properties.dataCollectionRuleId

// AMA extension provisioned with empty settings (no GCS override)
resources
| where type =~ 'microsoft.compute/virtualmachines/extensions'
| where name == 'AzureMonitorLinuxAgent' and id contains 'jesse-ama-test'
| project provisioningState = properties.provisioningState, settings = properties.settings
```

## End-to-End Verification

Submit jobs on the VM and watch the metric change:

```bash
ssh azladmin@<publicIp>
sudo -u slurm bash -c "cd /home/slurm && /usr/local/bin/sbatch --wrap='sleep 7200'"
/usr/local/bin/squeue
curl -sf http://127.0.0.1:6817/metrics/jobs | grep '^slurm_jobs_'
```

Then wait ~90s (60s scrape + ingest) and re-query Azure Monitor. `slurm_jobs_pending` and `slurm_jobs_running` should track `squeue` output.

Confirmed working: 569 total metrics flowing, 245+ `slurm_*` covering jobs, users, accounts, partitions, nodes, scheduler; `slurm_jobs_pending` transitions correctly as jobs are submitted and started.
