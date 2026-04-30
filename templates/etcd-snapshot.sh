#!/usr/bin/env bash
set -euo pipefail

BACKUP_DIR="/var/backups/etcd"
RETENTION_DAYS="${ETCD_SNAPSHOT_RETENTION_DAYS:-14}"
PKI_DIR="/etc/kubernetes/pki/etcd"

# AGE_RECIPIENT is set via systemd Environment= from var.etcd_snapshot_age_recipient.
# Snapshots WILL NOT be written without it: an etcd snapshot is the entire
# cluster state with every Secret value decrypted (etcdctl reads via the
# client API which decrypts on read), so plaintext snapshots leak Secrets to
# anyone who reads /var/backups/etcd/. Hard-fail rather than silently leak.
if [ -z "${AGE_RECIPIENT:-}" ]; then
  echo "ERROR: AGE_RECIPIENT not set — refusing to write a plaintext etcd snapshot." >&2
  echo "       Set var.etcd_snapshot_age_recipient in terraform.tfvars and re-apply." >&2
  exit 1
fi

mkdir -p "$BACKUP_DIR"
chmod 700 "$BACKUP_DIR"

TS=$(date -u +%Y%m%dT%H%M%SZ)
SNAP_ENC="$BACKUP_DIR/snapshot-$TS.db.age"

# etcdctl supports `snapshot save -` to write the snapshot to stdout; piping
# directly through age means the plaintext snapshot never touches disk.
# Previously we wrote $SNAP, then encrypted to $SNAP.age, then shredded —
# leaving a small window during which the plaintext (containing every
# decrypted Secret in the cluster) was readable from disk.
#
# etcdctl prints progress / "snapshot saved" to stderr on stdout-mode (the
# binary snapshot is the actual stdout). We let stderr through so a failure
# (etcd down, missing cert, wrong endpoint) lands in `journalctl -u
# etcd-snapshot.service` instead of being silently masked.
set -o pipefail
( umask 077 && \
  ETCDCTL_API=3 etcdctl \
    --endpoints=https://127.0.0.1:2379 \
    --cacert="$PKI_DIR/ca.crt" \
    --cert="$PKI_DIR/healthcheck-client.crt" \
    --key="$PKI_DIR/healthcheck-client.key" \
    snapshot save /dev/stdout \
  | age -r "$AGE_RECIPIENT" -o "$SNAP_ENC" )
chmod 600 "$SNAP_ENC"
SNAP="$SNAP_ENC"
echo "$(date -Is) snapshot encrypted with age recipient ${AGE_RECIPIENT} (no plaintext written)"

find "$BACKUP_DIR" -maxdepth 1 \( -name 'snapshot-*.db' -o -name 'snapshot-*.db.age' \) -mtime "+$RETENTION_DAYS" -delete

echo "$(date -Is) etcd snapshot $SNAP saved (retention ${RETENTION_DAYS}d)"
