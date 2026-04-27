locals {
  worker_user_data = [for i in range(var.worker_count) :
    templatefile("${path.module}/templates/cloud-init-worker.yaml.tftpl", {
      node_name           = local.worker_node_names[i]
      bootstrap_common_sh = local.bootstrap_common_sh
      kubeadm_join_yaml = templatefile("${path.module}/templates/kubeadm-join-worker.yaml.tftpl", {
        bootstrap_token   = local.bootstrap_token
        api_lb_private_ip = local.api_lb_private_ip
        self_node_name    = local.worker_node_names[i]
        ca_cert_hash      = local.ca_cert_hash
      })
      api_lb_private_ip        = local.api_lb_private_ip
      host_private_key_openssh = trimspace(tls_private_key.node_host_key[var.cp_count + i].private_key_openssh)
      host_public_key_openssh  = trimspace(tls_private_key.node_host_key[var.cp_count + i].public_key_openssh)
    })
  ]
}

resource "hcloud_server" "worker" {
  count       = var.worker_count
  name        = local.worker_node_names[count.index]
  image       = var.os_image
  server_type = var.worker_server_type
  location    = var.location
  ssh_keys    = [hcloud_ssh_key.admin.id]

  public_net {
    ipv4_enabled = true
    ipv6_enabled = true
  }

  user_data = local.worker_user_data[count.index]

  labels = {
    cluster = var.cluster_name
    role    = "worker"
  }

  lifecycle {
    ignore_changes = [user_data]
  }

  # Workers join with the bootstrap token (24h TTL on the cluster). On scale-up
  # weeks later the original token is long expired; refresh_join_secrets renews
  # it on every count-changing apply.
  depends_on = [
    hcloud_server.cp,
    null_resource.refresh_join_secrets,
  ]
}

resource "hcloud_server_network" "worker" {
  count      = var.worker_count
  server_id  = hcloud_server.worker[count.index].id
  network_id = hcloud_network.kubenet.id
  # IP not pinned — Hetzner picks the next free IP from the subnet. Stable per server-id;
  # never renumbered on scale up. Read back via local.worker_node_ips for outputs / SSH.
  # Each kubelet detects its own IP at runtime (bootstrap-common.sh).

  depends_on = [hcloud_network_subnet.kubenet]
}

resource "hcloud_volume_attachment" "worker" {
  count     = var.worker_count
  volume_id = hcloud_volume.osd[count.index].id
  server_id = hcloud_server.worker[count.index].id
  automount = false
}
