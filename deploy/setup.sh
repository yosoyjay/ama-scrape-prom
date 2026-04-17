#!/bin/bash
# Setup script: installs node-exporter, munge, slurmctld + prometheus-slurm-exporter
# on Ubuntu 22.04 and validates that both /metrics endpoints are reachable.
#
# Ubuntu 22.04 ships Slurm 21.08 which predates MetricsType=metrics/openmetrics
# (requires Slurm >= 22.05). We use rivosinc/prometheus-slurm-exporter instead,
# which polls Slurm CLI tools and exposes metrics on :9092/metrics.
#
set -euo pipefail
exec > /var/log/ama-setup.log 2>&1
echo "=== setup.sh start $(date) ==="

export DEBIAN_FRONTEND=noninteractive

# ── wait for cloud-init / unattended-upgrades to release dpkg lock ─────────
echo "Waiting for dpkg lock..."
while fuser /var/lib/dpkg/lock-frontend /var/lib/apt/lists/lock >/dev/null 2>&1; do
  sleep 5
done
echo "dpkg lock free."

# ── system packages ────────────────────────────────────────────────────────
apt-get update -y
apt-get install -y curl wget munge slurm-wlm prometheus-node-exporter

# ── node-exporter ──────────────────────────────────────────────────────────
systemctl enable prometheus-node-exporter
systemctl start  prometheus-node-exporter

# ── munge ─────────────────────────────────────────────────────────────────
if [ ! -f /etc/munge/munge.key ]; then
  mungekey --create --keyfile /etc/munge/munge.key
fi
chmod 400 /etc/munge/munge.key
chown munge:munge /etc/munge/munge.key
systemctl enable munge
systemctl start  munge

# ── slurm user + dirs ──────────────────────────────────────────────────────
if ! id slurm &>/dev/null; then
  groupadd -g 11100 slurm
  useradd  -u 11100 -d /home/slurm -m -g 11100 -s /usr/sbin/nologin slurm
fi

for d in /etc/slurm /var/spool/slurm /var/spool/slurm/slurmctld /var/run/slurm; do
  mkdir -p "$d"
  chmod 755 "$d"
  chown slurm:slurm "$d"
done

# ── slurm.conf ────────────────────────────────────────────────────────────
HOSTNAME=$(hostname)
CPUS=$(nproc)
MEM=$(awk '/MemTotal/{print int($2/1024)}' /proc/meminfo)

cat > /etc/slurm/slurm.conf << EOF
ClusterName=testcluster
SlurmctldHost=${HOSTNAME}
SlurmctldPort=6817
SlurmdPort=6818
MpiDefault=none
ProctrackType=proctrack/linuxproc
SelectType=select/cons_tres
SelectTypeParameters=CR_Core_Memory
SlurmctldPidFile=/var/run/slurm/slurmctld.pid
SlurmdSpoolDir=/var/spool/slurm
SlurmUser=slurm
StateSaveLocation=/var/spool/slurm/slurmctld
TaskPlugin=task/none
AccountingStorageType=accounting_storage/none
PartitionName=local Nodes=${HOSTNAME} Default=YES MaxTime=INFINITE State=UP
NodeName=${HOSTNAME} CPUs=${CPUS} RealMemory=${MEM} State=UNKNOWN
EOF
chown slurm:slurm /etc/slurm/slurm.conf

cat > /etc/slurm/cgroup.conf << EOF
CgroupMountpoint=/sys/fs/cgroup
ConstrainCores=no
ConstrainRAMSpace=no
EOF

# ── start slurmctld ───────────────────────────────────────────────────────
systemctl enable slurmctld
systemctl restart slurmctld

# ── prometheus-slurm-exporter (rivosinc, prebuilt .deb) ───────────────────
# Polls Slurm CLI tools; exposes metrics on :9092/metrics.
# Supports Slurm 21.x and newer via --slurm.cli-fallback flag.
EXPORTER_DEB_URL="https://github.com/rivosinc/prometheus-slurm-exporter/releases/download/v1.8.0/prometheus-slurm-exporter_1.8.0_linux_amd64.deb"
curl -sL "$EXPORTER_DEB_URL" -o /tmp/slurm-exporter.deb
dpkg -i /tmp/slurm-exporter.deb || true  # package has no postinst service, ignore failure

# Create systemd unit - the deb ships only the binary
cat > /etc/systemd/system/prometheus-slurm-exporter.service << 'UNIT'
[Unit]
Description=Prometheus Slurm Exporter
After=slurmctld.service

[Service]
Type=simple
ExecStart=/usr/bin/prometheus-slurm-exporter --slurm.cli-fallback
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
UNIT

systemctl daemon-reload
systemctl enable prometheus-slurm-exporter
systemctl restart prometheus-slurm-exporter

# ── wait for endpoints ────────────────────────────────────────────────────
echo "Waiting for node-exporter on :9100 ..."
for i in $(seq 1 30); do
  if curl -sf http://127.0.0.1:9100/metrics | grep -q '^node_'; then
    echo "  node-exporter OK (attempt ${i})"
    break
  fi
  sleep 2
done

echo "Waiting for slurm-exporter on :9092 ..."
for i in $(seq 1 60); do
  if curl -sf http://127.0.0.1:9092/metrics | grep -q '^slurm'; then
    echo "  slurm-exporter OK (attempt ${i})"
    break
  fi
  sleep 3
done

# ── final status ──────────────────────────────────────────────────────────
echo "=== Endpoint status ==="
echo "--- node-exporter :9100 ---"
curl -sf http://127.0.0.1:9100/metrics | grep '^node_' | head -5 || echo "NOT READY"
echo "--- slurm-exporter :9092 ---"
curl -sf http://127.0.0.1:9092/metrics | grep '^slurm' | head -5 || echo "NOT READY"

echo "=== setup.sh done $(date) ==="
