#!/usr/bin/env bash
set -euo pipefail

echo "$(date -Is) renewing kubeadm certificates"
kubeadm certs renew all

echo "$(date -Is) restarting static control-plane pods to pick up new certs"
for pod in kube-apiserver kube-controller-manager kube-scheduler etcd; do
  ids=$(crictl ps --name "$pod" -q || true)
  if [ -n "$ids" ]; then
    echo "  removing $pod containers: $ids"
    echo "$ids" | xargs -r crictl rm -f
  fi
done

echo "$(date -Is) restarting kubelet"
systemctl restart kubelet

echo "$(date -Is) cert renewal complete"
kubeadm certs check-expiration
