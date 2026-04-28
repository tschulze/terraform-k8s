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

# Calico WireGuard — pod-to-pod encryption (v4 + v6).
#
# Initial debugging on 2026-04-28 implicated WG in apiserver→webhook timeouts,
# but root cause was actually our NetworkPolicy design (`ipBlock: 10.0.0.0/24`
# source rule didn't match because `allow-intra-namespace` with empty
# podSelector was restricting webhook ingress to same-namespace only — the
# additional ipBlock rule didn't help because k8s NPs UNION their allows but
# only when the matched policies don't ALL fail). After fixing the NPs in the
# gitops repo (port-only ingress on webhook), basic WG works fine: cp→pod
# nc succeeded, full admission round-trip via cert-manager-webhook succeeded.
#
# `wireguardHostEncryptionEnabled` (extends WG to host-network sources) is
# left OFF for now: tested as a runtime patch on a healthy cluster and it
# cratered apiserver+etcd within seconds (cluster needed destroy/rebuild).
# Likely needs to ship at install time, not as a runtime toggle. TODO: try
# enabling it together with WG in this same patch on a fresh apply, with
# a short post-enable smoke check; revert if apiserver doesn't recover.
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

      echo "Enabling WireGuard (IPv4 + IPv6, pod-to-pod only)..."
      kubectl patch felixconfiguration default --type=merge \
        -p '{"spec":{"wireguardEnabled":true,"wireguardEnabledV6":true}}'

      echo "WireGuard enabled. Verify with:"
      echo "  kubectl get nodes -o jsonpath='{range .items[*]}{.metadata.name} wg={.metadata.annotations.projectcalico\\.org/WireguardPublicKey}{\"\\n\"}{end}'"
    EOT
  }

  depends_on = [null_resource.wait_for_calico]
}
