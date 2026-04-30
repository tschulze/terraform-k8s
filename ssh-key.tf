locals {
  ssh_key_provided = var.ssh_private_key_path != ""

  ssh_private_key_abs = local.ssh_key_provided ? pathexpand(var.ssh_private_key_path) : "${path.module}/secrets/${var.cluster_name}-ssh"
  ssh_public_key_abs  = "${local.ssh_private_key_abs}.pub"

  ssh_public_key_openssh = local.ssh_key_provided ? trimspace(file(local.ssh_public_key_abs)) : trimspace(tls_private_key.ssh[0].public_key_openssh)
}

resource "tls_private_key" "ssh" {
  count     = local.ssh_key_provided ? 0 : 1
  algorithm = "ED25519"
}

resource "local_sensitive_file" "ssh_private" {
  count           = local.ssh_key_provided ? 0 : 1
  filename        = local.ssh_private_key_abs
  content         = tls_private_key.ssh[0].private_key_openssh
  file_permission = "0600"
}

resource "local_file" "ssh_public" {
  count           = local.ssh_key_provided ? 0 : 1
  filename        = local.ssh_public_key_abs
  content         = tls_private_key.ssh[0].public_key_openssh
  file_permission = "0644"
}
