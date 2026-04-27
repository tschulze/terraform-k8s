locals {
  argocd_admin_password_blob = "${path.module}/secrets/argocd-admin-password.yaml.age"
}

# Persistent Argo CD admin password. Mirrors the sealed-secrets-master-key
# pattern (helm-sealed-secrets.tf): the encrypted blob is generated once via
# scripts/gen-argocd-admin-password.sh and committed to git. Decrypted at
# apply time and applied to the argocd namespace BEFORE the chart starts —
# the chart is configured with `configs.secret.createSecret: false`, so it
# uses our pre-existing Secret instead of generating a fresh random password
# on every fresh apply.
resource "null_resource" "argocd_admin_secret" {
  triggers = {
    blob_sha = try(filesha256(local.argocd_admin_password_blob), "missing")
  }

  provisioner "local-exec" {
    interpreter = ["bash", "-c"]
    command     = <<-EOT
      set -euo pipefail
      export KUBECONFIG="${local.kubeconfig_path}"
      kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f -
      age -d -i "${pathexpand(var.sealed_secrets_age_identity_path)}" \
        "${local.argocd_admin_password_blob}" \
        | kubectl apply -f -
    EOT
  }

  depends_on = [null_resource.fetch_kubeconfig]
}

resource "helm_release" "argocd" {
  name             = "argocd"
  namespace        = "argocd"
  create_namespace = true
  repository       = "https://argoproj.github.io/argo-helm"
  chart            = "argo-cd"
  version          = var.argocd_chart_version

  values = [
    templatefile("${path.module}/helm-values/argocd.values.yaml.tftpl", {
      hostname = var.argocd_hostname
    })
  ]

  depends_on = [
    null_resource.wait_for_calico,
    null_resource.argocd_admin_secret,
  ]
}

# App-of-Apps bootstrap. When var.argocd_repo_url is set, terraform creates:
#   1. The repository Secret in `argocd` (so Argo CD can clone the gitops repo)
#   2. The root Application CR (which syncs argocd_root_app_path from the repo)
# Everything else — child Applications, AppProjects, RBAC, HTTPRoutes,
# dashboards — lives in the gitops repo.
locals {
  argocd_bootstrap_enabled = var.argocd_repo_url != ""
  argocd_repo_ssh_key_abs  = "${path.module}/${var.argocd_repo_ssh_private_key_path}"
}

# Repository Secret. We use kubectl rather than kubernetes_secret_v1 so we can
# stuff the file contents straight in via --from-file without dragging the key
# through HCL string interpolation (where any embedded newline mishandling
# silently corrupts the SSH key and leaves you debugging git auth at 2am).
resource "null_resource" "argocd_repo_secret" {
  count = local.argocd_bootstrap_enabled ? 1 : 0

  triggers = {
    repo_url     = var.argocd_repo_url
    key_path     = local.argocd_repo_ssh_key_abs
    key_checksum = filesha256(local.argocd_repo_ssh_key_abs)
  }

  provisioner "local-exec" {
    interpreter = ["bash", "-c"]
    command     = <<-EOT
      set -euo pipefail
      export KUBECONFIG="${local.kubeconfig_path}"
      kubectl -n argocd wait --for=condition=Available --timeout=300s deployment argocd-server
      # create-or-replace via dry-run pipe so re-runs update the key cleanly
      kubectl -n argocd create secret generic argocd-repo-bootstrap \
        --from-literal=type=git \
        --from-literal=url='${var.argocd_repo_url}' \
        --from-file=sshPrivateKey='${local.argocd_repo_ssh_key_abs}' \
        --dry-run=client -o yaml | kubectl apply -f -
      kubectl -n argocd label secret argocd-repo-bootstrap \
        argocd.argoproj.io/secret-type=repository --overwrite
    EOT
  }

  depends_on = [helm_release.argocd]
}

locals {
  argocd_root_app_yaml = !local.argocd_bootstrap_enabled ? "" : <<-EOY
    apiVersion: argoproj.io/v1alpha1
    kind: Application
    metadata:
      name: bootstrap
      namespace: argocd
      finalizers:
        - resources-finalizer.argocd.argoproj.io
    spec:
      project: default
      source:
        repoURL: ${var.argocd_repo_url}
        targetRevision: ${var.argocd_root_app_revision}
        path: ${var.argocd_root_app_path}
        directory:
          recurse: true
      destination:
        server: https://kubernetes.default.svc
        namespace: argocd
      syncPolicy:
        automated:
          prune: true
          selfHeal: true
        syncOptions:
          - CreateNamespace=true
          - ServerSideApply=true
  EOY
}

resource "null_resource" "argocd_root_application" {
  count = local.argocd_bootstrap_enabled ? 1 : 0

  triggers = {
    root_app_hash = sha256(local.argocd_root_app_yaml)
  }

  provisioner "local-exec" {
    interpreter = ["bash", "-c"]
    command     = <<-EOT
      set -euo pipefail
      export KUBECONFIG="${local.kubeconfig_path}"
      # Wait for the Application CRD to be Established before applying the CR.
      kubectl wait --for=condition=Established --timeout=180s \
        crd/applications.argoproj.io
      cat <<'APP' | kubectl apply -f -
${local.argocd_root_app_yaml}
APP
    EOT
  }

  depends_on = [
    helm_release.argocd,
    null_resource.argocd_repo_secret,
  ]
}
