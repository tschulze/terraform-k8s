#!/usr/bin/env bash
# Reliable cluster teardown.
#
# Why this wrapper exists: any `helm_release` in state will block destroy
# waiting for in-cluster finalizers to drain. The terraform-managed bootstrap
# layer (Calico, kubelet-csr-approver, sealed-secrets, Argo CD itself) doesn't
# have finalizers that cause this directly, but Argo CD-managed Apps in the
# cluster (Rook-Ceph CephCluster, cert-manager Certificates, etc.) do — and
# their finalizers can outlive the operators that process them, holding
# Argo's Application resources Pending indefinitely.
#
# By removing every `helm_release.*` from state first, the in-cluster
# resources die naturally with the nodes (volumes detach, network is torn
# down, the whole VM is destroyed) instead of waiting for orderly drain.
#
# Usage: ./destroy.sh [extra terraform args]
set -euo pipefail
cd "$(dirname "$0")"

echo "==> Removing helm_release entries from state (avoid Rook destroy hang)..."
releases=$(terraform state list 2>/dev/null | grep '^helm_release\.' || true)
if [[ -n "$releases" ]]; then
  # shellcheck disable=SC2086 # word-splitting intentional — one address per line
  echo "$releases" | xargs -n1 terraform state rm
else
  echo "    (no helm_release entries in state — already clean)"
fi

echo "==> terraform destroy..."
terraform destroy -auto-approve "$@"

# Wipe stale kubeconfigs so the next `terraform apply` doesn't reuse the old
# cluster's CA cert. The kubernetes/helm providers cache the kubeconfig from
# first read — if secrets/admin.conf already exists with the previous cluster's
# CA when apply starts, every API call later in the apply hits TLS verification
# errors against the new cluster's certs (signed by a fresh kubeadm CA).
echo "==> Removing stale kubeconfigs from secrets/..."
rm -f secrets/admin.conf secrets/admin-*.conf
