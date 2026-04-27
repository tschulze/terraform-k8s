locals {
  sealed_secrets_master_key_blob = "${path.module}/secrets/sealed-secrets-master.key.yaml.age"
}

# Persistent master key. The encrypted blob is generated once via
# `scripts/gen-sealed-secrets-master-key.sh` and committed to git. Decrypted
# at apply time and applied to kube-system BEFORE the controller starts, so
# the controller adopts this key instead of generating its own. Survives
# `terraform destroy && terraform apply` — every SealedSecret committed in
# the gitops repo stays decryptable across cluster rebuilds.
resource "null_resource" "sealed_secrets_master_key" {
  # try() lets `terraform plan` work before the operator has run the helper
  # script for the first time. If the blob is missing at apply, the local-exec
  # fails with a clear `age: ... no such file or directory` error.
  triggers = {
    blob_sha = try(filesha256(local.sealed_secrets_master_key_blob), "missing")
  }

  provisioner "local-exec" {
    interpreter = ["bash", "-c"]
    command     = <<-EOT
      set -euo pipefail
      export KUBECONFIG="${local.kubeconfig_path}"
      age -d -i "${pathexpand(var.sealed_secrets_age_identity_path)}" \
        "${local.sealed_secrets_master_key_blob}" \
        | kubectl apply -f -
    EOT
  }

  depends_on = [null_resource.fetch_kubeconfig]
}

resource "helm_release" "sealed_secrets" {
  name             = "sealed-secrets"
  namespace        = "kube-system"
  create_namespace = false
  repository       = "https://bitnami-labs.github.io/sealed-secrets"
  chart            = "sealed-secrets"
  version          = var.sealed_secrets_chart_version

  values = [yamlencode({
    fullnameOverride = "sealed-secrets-controller" # canonical name expected by `kubeseal`
    resources = {
      requests = { cpu = "50m", memory = "64Mi" }
      limits   = { memory = "128Mi" }
    }
  })]

  depends_on = [
    null_resource.wait_for_calico,
    null_resource.sealed_secrets_master_key,
  ]
}
