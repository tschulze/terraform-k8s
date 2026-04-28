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

# The cluster CA carries lifecycle.prevent_destroy as a guard against an
# accidental `terraform taint` rotating the trust root. That guard would also
# block this scripted teardown. State-rm forgets the resource (no real
# infrastructure to destroy — tls_private_key is pure local material) so
# destroy can proceed; the next `terraform apply` regenerates a fresh CA.
echo "==> Removing cluster CA from state (prevent_destroy guard bypass)..."
ca_resources=$(terraform state list 2>/dev/null \
  | grep -E '^(tls_private_key|tls_self_signed_cert)\.cluster_ca$' || true)
if [[ -n "$ca_resources" ]]; then
  echo "$ca_resources" | xargs -n1 terraform state rm
else
  echo "    (no cluster CA in state — already clean)"
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
