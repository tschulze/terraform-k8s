locals {
  # Internal IPs for the two LBs in the Cloud Network. The kube-API LB private IP
  # is what kubeadm uses as controlPlaneEndpoint and what kubelet/workers connect to.
  api_lb_private_ip      = cidrhost(var.network_cidr, 2)
  services_lb_private_ip = cidrhost(var.network_cidr, 3)

  # Node private IPs are auto-assigned by Hetzner (no `ip` pin on hcloud_server_network).
  # Read back here for use in outputs / SSH config / known_hosts. Each kubelet detects its
  # own IP at runtime in bootstrap-common.sh and substitutes it into kubeadm config files,
  # so we don't need these values at template time.
  cp_node_ips     = hcloud_server_network.cp[*].ip
  worker_node_ips = hcloud_server_network.worker[*].ip

  cp_node_names     = [for i in range(var.cp_count) : "${var.cluster_name}-cp-${i}"]
  worker_node_names = [for i in range(var.worker_count) : "${var.cluster_name}-worker-${i}"]

  # bootstrap_token is sensitive via random_password; sensitive() on cert_key
  # makes random_id.hex behave the same way so the value is redacted in
  # `terraform plan` / `terraform show`. Both are kubeadm credentials that
  # rotate (24h / 2h) but logging them is still avoidable.
  bootstrap_token = sensitive("${random_password.bt_id.result}.${random_password.bt_secret.result}")
  cert_key        = sensitive(random_id.cert_key.hex)

  kubeconfig_path = "${path.module}/secrets/admin.conf"
}
