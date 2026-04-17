#!/bin/bash
# Setup script: installs node-exporter and Slurm 25.11 built from source so the
# native metrics/openmetrics plugin is available (introduced in 25.11, not in
# the 23.11 that Ubuntu 24.04 ships). slurmctld serves the Prometheus-format
# metrics directly on its RPC port (6817).
#
# Endpoints exposed by slurmctld on its RPC port (6817):
#   /metrics/jobs
#   /metrics/jobs-users-accts
#   /metrics/nodes
#   /metrics/partitions
#   /metrics/scheduler
#
set -euo pipefail
exec > /var/log/ama-setup.log 2>&1
echo "=== setup.sh start $(date) ==="

export DEBIAN_FRONTEND=noninteractive

# wait for cloud-init / unattended-upgrades to release dpkg lock
echo "Waiting for dpkg lock..."
while fuser /var/lib/dpkg/lock-frontend /var/lib/apt/lists/lock >/dev/null 2>&1; do
  sleep 5
done

apt-get update -y
apt-get install -y curl wget build-essential munge libmunge-dev \
  libhttp-parser-dev libyaml-dev libjson-c-dev libjwt-dev libdbus-1-dev \
  python3 pkg-config prometheus-node-exporter

# node-exporter
systemctl enable --now prometheus-node-exporter

# munge
if [ ! -f /etc/munge/munge.key ]; then
  mungekey --create --keyfile /etc/munge/munge.key
fi
chmod 400 /etc/munge/munge.key
chown munge:munge /etc/munge/munge.key
systemctl enable --now munge

# slurm user
if ! id slurm &>/dev/null; then
  groupadd -g 11100 slurm
  useradd  -u 11100 -d /home/slurm -m -g 11100 -s /usr/sbin/nologin slurm
fi

# build Slurm 25.11 from source (only version with metrics/openmetrics plugin)
SLURM_VER=25.11.5
SLURM_TARBALL="slurm-${SLURM_VER}.tar.bz2"
cd /tmp
curl -sfL "https://download.schedmd.com/slurm/${SLURM_TARBALL}" -o "${SLURM_TARBALL}"
tar -xjf "${SLURM_TARBALL}"
cd "slurm-${SLURM_VER}"
./configure --prefix=/usr/local --sysconfdir=/etc/slurm --with-munge \
  --with-http-parser --with-yaml --with-jwt
make -j"$(nproc)"
make install
ldconfig

# verify openmetrics plugin built
ls /usr/local/lib/slurm/metrics_openmetrics.so

for d in /etc/slurm /var/spool/slurm /var/spool/slurm/slurmctld /var/run/slurm /var/log/slurm; do
  mkdir -p "$d"
  chown slurm:slurm "$d"
done

HOSTNAME=$(hostname)
CPUS=$(nproc)
MEM=$(awk '/MemTotal/{print int($2/1024)}' /proc/meminfo)

# slurm.conf with MetricsType=metrics/openmetrics enabled.
# The openmetrics plugin serves HTTP endpoints on the existing slurmctld port
# (6817), no extra parameter required. Confirmed via curl http://:6817/metrics.
cat > /etc/slurm/slurm.conf <<EOF
ClusterName=testcluster
SlurmctldHost=${HOSTNAME}
SlurmctldPort=6817
SlurmdPort=6818
MpiDefault=none
ProctrackType=proctrack/linuxproc
SelectType=select/cons_tres
SelectTypeParameters=CR_Core_Memory
SlurmctldPidFile=/var/run/slurm/slurmctld.pid
SlurmdPidFile=/var/run/slurm/slurmd.pid
SlurmdSpoolDir=/var/spool/slurm
SlurmUser=slurm
StateSaveLocation=/var/spool/slurm/slurmctld
TaskPlugin=task/none
AccountingStorageType=accounting_storage/none
SlurmctldLogFile=/var/log/slurm/slurmctld.log
SlurmdLogFile=/var/log/slurm/slurmd.log
MetricsType=metrics/openmetrics
PartitionName=local Nodes=${HOSTNAME} Default=YES MaxTime=INFINITE State=UP
NodeName=${HOSTNAME} CPUs=${CPUS} RealMemory=${MEM} State=UNKNOWN
EOF
chown slurm:slurm /etc/slurm/slurm.conf

cat > /etc/slurm/cgroup.conf <<EOF
CgroupMountpoint=/sys/fs/cgroup
ConstrainCores=no
ConstrainRAMSpace=no
EOF
chown slurm:slurm /etc/slurm/cgroup.conf

# systemd units (source build doesn't install them)
cat > /etc/systemd/system/slurmctld.service <<'UNIT'
[Unit]
Description=Slurm controller daemon
After=network-online.target munge.service
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/local/sbin/slurmctld -D
Restart=on-failure
RestartSec=5
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
UNIT

cat > /etc/systemd/system/slurmd.service <<'UNIT'
[Unit]
Description=Slurm node daemon
After=network-online.target munge.service
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/local/sbin/slurmd -D
Restart=on-failure
RestartSec=5
LimitNOFILE=65536
LimitMEMLOCK=infinity

[Install]
WantedBy=multi-user.target
UNIT

systemctl daemon-reload
systemctl enable --now slurmctld
systemctl enable --now slurmd

# wait for node-exporter
echo "Waiting for node-exporter on :9100 ..."
for i in $(seq 1 30); do
  if curl -sf http://127.0.0.1:9100/metrics | grep -q '^node_'; then
    echo "  node-exporter OK (attempt ${i})"; break
  fi
  sleep 2
done

# wait for slurmctld openmetrics endpoint (served on the slurmctld RPC port)
echo "Waiting for slurmctld openmetrics on :6817 ..."
for i in $(seq 1 60); do
  if curl -sf http://127.0.0.1:6817/metrics/jobs | grep -q '^slurm_'; then
    echo "  openmetrics OK (attempt ${i})"; break
  fi
  sleep 3
done

# submit a dummy job so job metrics populate (run from /home/slurm so stdout
# file is writable; otherwise IO setup fails and the job exits immediately)
sudo -u slurm bash -c "cd /home/slurm && /usr/local/bin/sbatch --wrap='sleep 3600'" || true

echo "=== Endpoint status ==="
echo "--- node-exporter :9100 ---"
curl -sf http://127.0.0.1:9100/metrics | grep '^node_' | head -3 || echo "NOT READY"
echo "--- slurm openmetrics :6817/metrics/jobs ---"
curl -sf http://127.0.0.1:6817/metrics/jobs | head -20 || echo "NOT READY"
echo "--- slurm openmetrics :6817/metrics/nodes ---"
curl -sf http://127.0.0.1:6817/metrics/nodes | head -10 || echo "NOT READY"

echo "=== setup.sh done $(date) ==="
