locals {
  # Host keys for every cluster endpoint, written into the user's ~/.ssh/known_hosts
  # by null_resource.user_known_hosts below. No project-local known_hosts file is
  # needed — SSH and the kubeconfig fetch use the OpenSSH default location.
  known_hosts_content = join("\n", concat(
    # Per-node: private IPv4 + public IPv6 pinned to each node's own host key
    [for i in range(var.cp_count) :
      "${local.cp_node_ips[i]},${cidrhost(hcloud_server.cp[i].ipv6_network, 1)} ${trimspace(tls_private_key.node_host_key[i].public_key_openssh)}"
    ],
    [for i in range(var.worker_count) :
      "${local.worker_node_ips[i]},${cidrhost(hcloud_server.worker[i].ipv6_network, 1)} ${trimspace(tls_private_key.node_host_key[var.cp_count + i].public_key_openssh)}"
    ],
    # LB jump host (k8s / k8s-v6): forwards :2222 to ANY CP's :22, so we trust every
    # CP's host key on the LB endpoint. OpenSSH treats multiple lines for the same
    # host as alternatives — connection succeeds if the seen key matches any one.
    [for i in range(var.cp_count) :
      "[${hcloud_load_balancer.k8s_api.ipv4}]:${var.kube_api_lb_ssh_port},[${hcloud_load_balancer.k8s_api.ipv6}]:${var.kube_api_lb_ssh_port} ${trimspace(tls_private_key.node_host_key[i].public_key_openssh)}"
    ]
  ))
  known_hosts_marker = "terraform-k8s:${var.cluster_name}"
}

resource "null_resource" "user_known_hosts" {
  triggers = {
    content_hash = sha256(local.known_hosts_content)
    marker       = local.known_hosts_marker
  }

  provisioner "local-exec" {
    interpreter = ["bash", "-c"]
    # Body NOT indented because the inner `<<'KH'` heredoc content must reach bash
    # at column 0 — known_hosts entries with leading whitespace fail to parse.
    command = <<EOT
set -euo pipefail
mkdir -p ~/.ssh
touch ~/.ssh/known_hosts
chmod 600 ~/.ssh/known_hosts
sed -i.bak '/^# BEGIN ${local.known_hosts_marker}$/,/^# END ${local.known_hosts_marker}$/d' ~/.ssh/known_hosts
rm -f ~/.ssh/known_hosts.bak
cat >> ~/.ssh/known_hosts <<'KH'
# BEGIN ${local.known_hosts_marker}
${local.known_hosts_content}
# END ${local.known_hosts_marker}
KH
EOT
  }

  provisioner "local-exec" {
    when        = destroy
    interpreter = ["bash", "-c"]
    command     = <<EOT
[ -f ~/.ssh/known_hosts ] || exit 0
sed -i.bak '/^# BEGIN ${self.triggers.marker}$/,/^# END ${self.triggers.marker}$/d' ~/.ssh/known_hosts
rm -f ~/.ssh/known_hosts.bak
EOT
  }
}

resource "null_resource" "fetch_kubeconfig" {
  triggers = {
    cp0_id           = hcloud_server.cp[0].id
    known_hosts_hash = sha256(local.known_hosts_content)
    ssh_config       = local_file.ssh_config.content
  }

  provisioner "local-exec" {
    interpreter = ["bash", "-c"]
    command     = <<-EOT
      set -euo pipefail
      mkdir -p "${path.module}/secrets"

      # ssh -F uses our generated config; host keys come from the user's default
      # ~/.ssh/known_hosts (populated by null_resource.user_known_hosts).
      SSH_OPTS="-F ${local_file.ssh_config.filename} -o ConnectTimeout=10"
      CP0="${local.cp_node_names[0]}"

      echo "Waiting for kubeadm init on cp[0] via LB jump (up to 30 min)..."
      READY=0
      for _ in $(seq 1 60); do
        if ssh $SSH_OPTS "$CP0" 'test -f /root/kubeadm-init.done' 2>/dev/null; then
          echo "kubeadm init complete."
          READY=1
          break
        fi
        echo "  not ready yet, sleeping 30s"
        sleep 30
      done

      # Don't re-test with a fresh SSH call here — the LB-jump connection often
      # gets dropped immediately after the polling SSH succeeds, which would
      # spuriously fail the verification even though the marker is on disk.
      if [ "$READY" != "1" ]; then
        echo "ERROR: kubeadm init did not complete in time" >&2
        exit 1
      fi

      echo "Fetching admin.conf from $CP0..."
      # Retry: the LB-jump SSH layer occasionally drops the first new connection
      # right after the polling SSH closed (likely sshd reload during cloud-init
      # finalization). 5 tries with 5s backoff is enough.
      for try in 1 2 3 4 5; do
        if scp $SSH_OPTS "$CP0:/etc/kubernetes/admin.conf" "${local.kubeconfig_path}"; then
          break
        fi
        echo "  scp attempt $try failed, sleeping 5s"
        sleep 5
        [ "$try" = "5" ] && { echo "ERROR: scp admin.conf failed after 5 tries" >&2; exit 1; }
      done
      chmod 600 "${local.kubeconfig_path}"

      EXTERNAL_URL="https://${hcloud_load_balancer.k8s_api.ipv4}:6443"
      echo "Rewriting kubeconfig server URL to $EXTERNAL_URL"
      sed -i.bak "s|server:.*|server: $EXTERNAL_URL|" "${local.kubeconfig_path}"
      rm -f "${local.kubeconfig_path}.bak"
    EOT
  }

  depends_on = [
    hcloud_server_network.cp,
    null_resource.user_known_hosts,
    local_file.ssh_config,
    hcloud_load_balancer_target.k8s_api,
    hcloud_load_balancer_service.k8s_api,
    hcloud_load_balancer_service.k8s_ssh_jump,
  ]
}
