# Auto-approves kubelet serving-cert CSRs so kubelets get a serving cert signed
# by the cluster CA (instead of self-signed). Pairs with `serverTLSBootstrap:
# true` in templates/kubeadm-config.yaml.tftpl. Lets metrics-server (and any
# future apiserver→kubelet:10250 client) verify the chain end-to-end and drop
# --kubelet-insecure-tls.
#
# bypassDnsResolution=true skips reverse-DNS verification of the SANs in the
# CSR — we don't put node hostnames in cluster DNS, only in /etc/hosts on each
# node. The CSR's CN is still scoped to the requesting node's bootstrap
# kubeconfig (system:node:k8s-cp-N or system:node:k8s-worker-N), so a
# compromised node can only request a cert for its own SANs.
resource "helm_release" "kubelet_csr_approver" {
  name             = "kubelet-csr-approver"
  namespace        = "kube-system"
  create_namespace = false
  repository       = "https://postfinance.github.io/kubelet-csr-approver"
  chart            = "kubelet-csr-approver"
  version          = var.kubelet_csr_approver_chart_version

  values = [yamlencode({
    # providerRegex matches against the DNS SAN names in the CSR (the node's
    # hostname like "k8s-cp-0"), NOT the system:node:... requestor. The
    # requestor is RBAC-scoped to its own node by the chart's ClusterRoleBinding.
    # Uses var.cluster_name so changing the prefix doesn't silently break CSR
    # approval (which would tank metrics-server scrapes).
    #
    # Index is bounded to the actual deployed counts (cp_count - 1 / worker_count - 1)
    # rather than `[0-9]+`. An open index would let a node with bootstrap
    # credentials request a serving cert for an arbitrary hostname like
    # `k8s-worker-9999` (still RBAC-scoped to the requesting node, but the
    # serving cert's SAN list would be attacker-controlled within our naming
    # scheme).
    providerRegex       = "^${var.cluster_name}-(cp-(${join("|", [for i in range(var.cp_count) : tostring(i)])})|worker-(${join("|", [for i in range(max(var.worker_count, 1)) : tostring(i)])}))$"
    bypassDnsResolution = true
    bypassHostnameCheck = true

    resources = {
      requests = { cpu = "10m", memory = "32Mi" }
      limits   = { memory = "64Mi" }
    }
  })]

  depends_on = [null_resource.wait_for_calico]
}
