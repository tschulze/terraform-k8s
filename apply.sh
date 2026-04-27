#!/usr/bin/env bash
# Wrapper for `terraform apply` that ensures local state files end up with
# restrictive permissions.
#
# Why this exists: terraform.tfstate contains plaintext secrets (etcd
# encryption key, kubeadm cert_key, every node's SSH host private key, every
# admin's RSA private key, bootstrap token). Default umask on macOS produces
# 0644 state files, world-readable for any process running as your UID.
# Setting `umask 077` here makes terraform create the new state and .backup
# files at 0600. The trailing chmod is belt-and-suspenders for any pre-existing
# files that pre-date this script.
#
# Usage: ./apply.sh [extra terraform args]
#   passes all args through to `terraform apply -auto-approve`.

set -euo pipefail
cd "$(dirname "$0")"

umask 077

terraform apply -auto-approve "$@"

# Belt-and-suspenders chmod (covers files created before this script existed)
chmod 600 terraform.tfstate* 2>/dev/null || true
