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

# Calico WireGuard — DISABLED 2026-04-28.
#
# Was enabled yesterday (2026-04-27) as part of an inter-node encryption
# hardening pass. Smoke test today (2026-04-28) found it breaks
# apiserver→pod webhook calls: kube-apiserver runs hostNetwork on cp nodes,
# and with WireGuard enabled Calico's iptables / FIB rules drop or misroute
# the host→pod-network path. Symptom: every admission webhook (cert-manager,
# kyverno) times out with "context deadline exceeded", which then cascades
# (Rook's ceph-version detection job is admission-checked → blocked → cluster
# stuck Progressing).
#
# Validated by patching `wireguardEnabled=false` live and watching nc from
# cp-0 → webhook pod IP go from "timed out" to "succeeded".
#
# To re-enable safely, the right knob is probably `wireguardHostEncryptionEnabled`
# (Calico ≥3.27) which extends WG to host-network sources. Needs separate
# testing — leaving disabled until then so the cluster boots cleanly.
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

      # Belt-and-suspenders: ensure WG stays off in case a previous state had
      # it enabled. Idempotent no-op when already false.
      kubectl patch felixconfiguration default --type=merge \
        -p '{"spec":{"wireguardEnabled":false,"wireguardEnabledV6":false}}'

      echo "WireGuard remains disabled (see comment in this file for why)."
    EOT
  }

  depends_on = [null_resource.wait_for_calico]
}
