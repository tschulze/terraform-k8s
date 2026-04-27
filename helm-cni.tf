resource "helm_release" "tigera_operator" {
  name             = "tigera-operator"
  namespace        = "tigera-operator"
  create_namespace = true
  repository       = "https://docs.tigera.io/calico/charts"
  chart            = "tigera-operator"
  version          = trimprefix(var.tigera_operator_chart_version, "v")

  values = [
    templatefile("${path.module}/helm-values/tigera-operator.values.yaml.tftpl", {
      pod_cidr_v4 = var.pod_cidr_v4
      pod_cidr_v6 = var.pod_cidr_v6
    })
  ]

  depends_on = [null_resource.fetch_kubeconfig]
}

resource "null_resource" "wait_for_calico" {
  triggers = {
    tigera_release_id = helm_release.tigera_operator.id
  }

  provisioner "local-exec" {
    interpreter = ["bash", "-c"]
    command     = <<-EOT
      set -euo pipefail
      export KUBECONFIG="${local.kubeconfig_path}"
      echo "Waiting for all nodes to be Ready (Calico CNI installed)..."
      kubectl wait --for=condition=Ready nodes --all --timeout=600s
    EOT
  }

  depends_on = [helm_release.tigera_operator]
}

# Enable Calico WireGuard for node-to-node pod traffic encryption (v4 + v6).
# Tigera operator's Installation CR doesn't expose WireGuard fields; they live on
# the cluster-wide FelixConfiguration "default" which Calico creates on bootstrap.
# We wait for it then patch.
resource "null_resource" "calico_wireguard" {
  triggers = {
    wait_id = null_resource.wait_for_calico.id
  }

  provisioner "local-exec" {
    interpreter = ["bash", "-c"]
    command     = <<-EOT
      set -euo pipefail
      export KUBECONFIG="${local.kubeconfig_path}"

      echo "Waiting for FelixConfiguration default to exist..."
      for _ in $(seq 1 60); do
        if kubectl get felixconfiguration default >/dev/null 2>&1; then
          echo "FelixConfiguration default present."
          break
        fi
        sleep 5
      done

      kubectl get felixconfiguration default >/dev/null \
        || { echo "ERROR: FelixConfiguration default never appeared"; exit 1; }

      echo "Enabling WireGuard (IPv4 + IPv6) on Calico..."
      kubectl patch felixconfiguration default --type=merge \
        -p '{"spec":{"wireguardEnabled":true,"wireguardEnabledV6":true}}'

      echo "WireGuard enabled. Verify with: kubectl get nodes -o jsonpath='{.items[*].status.addresses}' and 'wg show' on a node."
    EOT
  }

  depends_on = [null_resource.wait_for_calico]
}
