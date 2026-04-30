locals {
  bootstrap_common_sh = templatefile("${path.module}/templates/bootstrap-common.sh.tftpl", {
    kubernetes_version        = var.kubernetes_version
    apt_keyring_sha256_docker = var.apt_keyring_sha256_docker
    apt_keyring_sha256_k8s    = var.apt_keyring_sha256_k8s
  })

  encryption_config_yaml = templatefile("${path.module}/templates/encryption-config.yaml.tftpl", {
    active_key_name   = "key-${substr(random_id.encryption_key.hex, 0, 8)}"
    active_key_secret = random_id.encryption_key.b64_std
    retired_keys      = var.etcd_retired_encryption_keys
  })

  audit_policy_yaml          = file("${path.module}/templates/audit-policy.yaml.tftpl")
  admission_config_yaml      = file("${path.module}/templates/admission-config.yaml.tftpl")
  authentication_config_yaml = file("${path.module}/templates/authentication-config.yaml.tftpl")

  etcd_snapshot_sh = file("${path.module}/templates/etcd-snapshot.sh")
  cert_renew_sh    = file("${path.module}/templates/cert-renew.sh")

  # Fresh kubeadm init/join on each CP detects its own private IP and adds it
  # to the apiserver cert automatically (via localAPIEndpoint.advertiseAddress).
  # Including cp_node_ips here would create a cycle (server → cert → kubeadm
  # config → cloud-init → server). Live cluster cert rotations via
  # `kubeadm init phase certs apiserver --config <file>` need the CP IPs added
  # in-cluster (edit the kubeadm-config CM) since that path doesn't auto-detect.
  cert_sans = compact([
    local.api_lb_private_ip,
    hcloud_load_balancer.k8s_api.ipv4,
    hcloud_load_balancer.k8s_api.ipv6,
    var.cluster_dns_zone != "" ? "api.${var.cluster_dns_zone}" : "",
    "kubernetes",
    "kubernetes.default",
    "kubernetes.default.svc",
    "kubernetes.default.svc.cluster.local",
    "${var.cluster_name}.local",
  ])

  cp0_kubeadm_config = templatefile("${path.module}/templates/kubeadm-config.yaml.tftpl", {
    bootstrap_token    = local.bootstrap_token
    cert_key           = local.cert_key
    cp0_node_name      = local.cp_node_names[0]
    cluster_name       = var.cluster_name
    api_lb_private_ip  = local.api_lb_private_ip
    kubernetes_version = var.kubernetes_version
    pod_cidr_v4        = var.pod_cidr_v4
    pod_cidr_v6        = var.pod_cidr_v6
    service_cidr_v4    = var.service_cidr_v4
    service_cidr_v6    = var.service_cidr_v6
    cert_sans          = local.cert_sans
  })

  cp0_user_data = templatefile("${path.module}/templates/cloud-init-cp-bootstrap.yaml.tftpl", {
    node_name                  = local.cp_node_names[0]
    bootstrap_common_sh        = local.bootstrap_common_sh
    kubeadm_config_yaml        = local.cp0_kubeadm_config
    encryption_config_yaml     = local.encryption_config_yaml
    audit_policy_yaml          = local.audit_policy_yaml
    admission_config_yaml      = local.admission_config_yaml
    authentication_config_yaml = local.authentication_config_yaml
    etcd_snapshot_sh           = local.etcd_snapshot_sh
    cert_renew_sh              = local.cert_renew_sh
    etcd_age_recipient         = var.etcd_snapshot_age_recipient
    host_private_key_openssh   = trimspace(tls_private_key.node_host_key[0].private_key_openssh)
    host_public_key_openssh    = trimspace(tls_private_key.node_host_key[0].public_key_openssh)
    # Pre-placed cluster CA so kubeadm init adopts instead of generating.
    cluster_ca_cert_pem = trimspace(tls_self_signed_cert.cluster_ca.cert_pem)
    cluster_ca_key_pem  = trimspace(tls_private_key.cluster_ca.private_key_pem)
  })

  cp_join_user_data = [for i in range(var.cp_count) :
    i == 0 ? "" : templatefile("${path.module}/templates/cloud-init-cp-join.yaml.tftpl", {
      node_name                  = local.cp_node_names[i]
      bootstrap_common_sh        = local.bootstrap_common_sh
      encryption_config_yaml     = local.encryption_config_yaml
      audit_policy_yaml          = local.audit_policy_yaml
      admission_config_yaml      = local.admission_config_yaml
      authentication_config_yaml = local.authentication_config_yaml
      etcd_snapshot_sh           = local.etcd_snapshot_sh
      cert_renew_sh              = local.cert_renew_sh
      etcd_age_recipient         = var.etcd_snapshot_age_recipient
      kubeadm_join_yaml = templatefile("${path.module}/templates/kubeadm-join-cp.yaml.tftpl", {
        bootstrap_token   = local.bootstrap_token
        cert_key          = local.cert_key
        api_lb_private_ip = local.api_lb_private_ip
        self_node_name    = local.cp_node_names[i]
        ca_cert_hash      = local.ca_cert_hash
      })
      api_lb_private_ip        = local.api_lb_private_ip
      host_private_key_openssh = trimspace(tls_private_key.node_host_key[i].private_key_openssh)
      host_public_key_openssh  = trimspace(tls_private_key.node_host_key[i].public_key_openssh)
    })
  ]
}

resource "hcloud_server" "cp" {
  count       = var.cp_count
  name        = local.cp_node_names[count.index]
  image       = var.os_image
  server_type = var.cp_server_type
  location    = var.location
  ssh_keys    = [hcloud_ssh_key.admin.id]

  public_net {
    ipv4_enabled = true
    ipv6_enabled = true
  }

  user_data = count.index == 0 ? local.cp0_user_data : local.cp_join_user_data[count.index]

  labels = {
    cluster = var.cluster_name
    role    = "control-plane"
  }

  lifecycle {
    ignore_changes = [user_data]
  }

  # On scale-up the new cp[N+1..] need a freshly-uploaded kubeadm-certs Secret
  # (2h TTL) and a registered bootstrap token (24h TTL) on the cluster. The
  # refresh_join_secrets null_resource handles both via SSH to a CP. Existing
  # CPs are not affected (depends_on is ordering only, not recreation).
  depends_on = [null_resource.refresh_join_secrets]
}

resource "hcloud_server_network" "cp" {
  count      = var.cp_count
  server_id  = hcloud_server.cp[count.index].id
  network_id = hcloud_network.kubenet.id
  # IP not pinned — Hetzner picks the next free IP from the subnet. Stable per server-id;
  # never renumbered on scale up. Read back via local.cp_node_ips for outputs / SSH config.
  # Each kubelet detects its own IP at runtime (bootstrap-common.sh).

  depends_on = [hcloud_network_subnet.kubenet]
}
