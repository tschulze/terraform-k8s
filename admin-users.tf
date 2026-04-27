# Personal cluster-admin kubeconfigs.
# For each name in var.admin_users we generate an RSA keypair, get a 1-year client
# cert via the cluster's CSR API (kubernetes.io/kube-apiserver-client signer), bind
# the user to cluster-admin via RBAC, and write two kubeconfig files:
#   secrets/admin-<name>-v4.conf  (server = LB public IPv4)
#   secrets/admin-<name>-v6.conf  (server = LB public IPv6)
#
# Identity is the bare CN (no Organization), so RBAC is via the explicit
# ClusterRoleBinding — no system:masters back-door, fully revocable by removing
# the name from var.admin_users.

resource "tls_private_key" "admin_user" {
  for_each  = toset(var.admin_users)
  algorithm = "RSA"
  rsa_bits  = 4096
}

resource "tls_cert_request" "admin_user" {
  for_each        = toset(var.admin_users)
  private_key_pem = tls_private_key.admin_user[each.key].private_key_pem
  subject {
    common_name = each.key
  }
}

# Submit the CSR + auto-approve + grant cluster-admin via RBAC.
# Done in a single null_resource because the kubernetes provider can't be used at
# plan time (kubeconfig doesn't exist yet on first apply).
resource "null_resource" "admin_user_csr" {
  for_each = toset(var.admin_users)

  triggers = {
    user            = each.key
    csr_pem_sha     = sha256(tls_cert_request.admin_user[each.key].cert_request_pem)
    kubeconfig_path = local.kubeconfig_path
  }

  provisioner "local-exec" {
    interpreter = ["bash", "-c"]
    command     = <<-EOT
      set -euo pipefail
      U=${each.key}
      KCFG=${local.kubeconfig_path}
      CSR_B64=$(printf '%s' '${tls_cert_request.admin_user[each.key].cert_request_pem}' | base64 | tr -d '\n')

      # 1. Submit CSR
      cat <<YAML | kubectl --kubeconfig "$KCFG" apply -f -
      apiVersion: certificates.k8s.io/v1
      kind: CertificateSigningRequest
      metadata:
        name: admin-$U
      spec:
        request: $CSR_B64
        signerName: kubernetes.io/kube-apiserver-client
        expirationSeconds: 31536000
        usages: [client auth]
      YAML

      # 2. Approve (idempotent — already-approved CSRs are no-op)
      kubectl --kubeconfig "$KCFG" certificate approve "admin-$U" >/dev/null

      # 3. Wait for csrsigner controller to populate .status.certificate
      CERT=""
      for _ in $(seq 1 30); do
        CERT=$(kubectl --kubeconfig "$KCFG" get csr "admin-$U" -o jsonpath='{.status.certificate}' 2>/dev/null || true)
        [[ -n "$CERT" ]] && break
        sleep 1
      done
      [[ -n "$CERT" ]] || { echo "ERROR: CSR admin-$U was not signed within 30s" >&2; exit 1; }

      # 4. Bind to cluster-admin
      cat <<YAML | kubectl --kubeconfig "$KCFG" apply -f -
      apiVersion: rbac.authorization.k8s.io/v1
      kind: ClusterRoleBinding
      metadata:
        name: admin-user-$U
      roleRef:
        apiGroup: rbac.authorization.k8s.io
        kind: ClusterRole
        name: cluster-admin
      subjects:
        - kind: User
          name: $U
          apiGroup: rbac.authorization.k8s.io
      YAML

      # 5. Persist the signed cert (base64-encoded as-is from API) for the
      #    local_file resources below to read via data.local_file.
      mkdir -p "${path.module}/secrets"
      printf '%s' "$CERT" > "${path.module}/secrets/.admin-$U.crt.b64"
      chmod 600 "${path.module}/secrets/.admin-$U.crt.b64"
    EOT
  }

  provisioner "local-exec" {
    when        = destroy
    interpreter = ["bash", "-c"]
    # Best-effort cleanup. --request-timeout=10s prevents kubectl from hanging
    # for ~10 minutes on connection retries when the apiserver/LB is already
    # gone (other resources destroying in parallel). Errors are swallowed.
    command = <<-EOT
      KCFG=${self.triggers.kubeconfig_path}
      U=${self.triggers.user}
      KCTL="kubectl --kubeconfig $KCFG --request-timeout=10s"
      $KCTL delete csr "admin-$U" --ignore-not-found 2>/dev/null || true
      $KCTL delete clusterrolebinding "admin-user-$U" --ignore-not-found 2>/dev/null || true
      rm -f "${path.module}/secrets/.admin-$U.crt.b64"
    EOT
  }

  depends_on = [null_resource.fetch_kubeconfig]
}

# Inputs to the kubeconfig template come from files written at apply-time
# (admin.conf by null_resource.fetch_kubeconfig, .admin-<U>.crt.b64 by
# null_resource.admin_user_csr). Using `data "local_file"` here would fail at
# refresh-time when those files don't exist (e.g. partial-state destroy after
# an interrupted apply). `try(file(...), "")` returns "" instead — the
# downstream local_file.admin_user_kubeconfig_v{4,6} resources end up with
# empty placeholder values during destroy, which is fine because they're
# being destroyed too.
locals {
  admin_user_cert = {
    for u in var.admin_users :
    u => try(trimspace(file("${path.module}/secrets/.admin-${u}.crt.b64")), "")
  }

  cluster_ca_data = try(
    yamldecode(file(local.kubeconfig_path)).clusters[0].cluster["certificate-authority-data"],
    ""
  )

  # Prefer the api DNS name (api.<cluster_dns_zone>) when DNS automation is on;
  # otherwise fall back to the LB IPs. The DNS name only works after the
  # apiserver cert has been rotated to include it as a SAN — automatic on a
  # fresh cluster, manual on an existing one (kubeadm init phase certs apiserver
  # on each CP, then restart the apiserver static pods).
  api_endpoint_v4 = var.cluster_dns_zone != "" ? "api.${var.cluster_dns_zone}" : hcloud_load_balancer.k8s_api.ipv4
  api_endpoint_v6 = var.cluster_dns_zone != "" ? "api.${var.cluster_dns_zone}" : "[${hcloud_load_balancer.k8s_api.ipv6}]"
}

resource "local_file" "admin_user_kubeconfig_v4" {
  for_each        = toset(var.admin_users)
  filename        = "${path.module}/secrets/admin-${each.key}-v4.conf"
  file_permission = "0600"
  content = templatefile("${path.module}/templates/admin-user-kubeconfig.yaml.tftpl", {
    user_name        = each.key
    cluster_name     = var.cluster_name
    server_url       = "https://${local.api_endpoint_v4}:6443"
    cluster_ca_data  = local.cluster_ca_data
    client_cert_data = local.admin_user_cert[each.key]
    client_key_data  = base64encode(tls_private_key.admin_user[each.key].private_key_pem)
  })
}

resource "local_file" "admin_user_kubeconfig_v6" {
  for_each        = toset(var.admin_users)
  filename        = "${path.module}/secrets/admin-${each.key}-v6.conf"
  file_permission = "0600"
  content = templatefile("${path.module}/templates/admin-user-kubeconfig.yaml.tftpl", {
    user_name        = each.key
    cluster_name     = var.cluster_name
    server_url       = "https://${local.api_endpoint_v6}:6443"
    cluster_ca_data  = local.cluster_ca_data
    client_cert_data = local.admin_user_cert[each.key]
    client_key_data  = base64encode(tls_private_key.admin_user[each.key].private_key_pem)
  })
}

output "admin_user_kubeconfigs" {
  description = "Per-user kubeconfig file paths (v4 + v6 endpoints)."
  value = {
    for u in var.admin_users : u => {
      v4 = local_file.admin_user_kubeconfig_v4[u].filename
      v6 = local_file.admin_user_kubeconfig_v6[u].filename
    }
  }
}
