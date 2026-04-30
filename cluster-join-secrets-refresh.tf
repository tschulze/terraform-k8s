# Refresh the cluster-side join secrets on every apply, so scaling up CPs or
# workers always works regardless of cluster age.
#
# Two short-lived secrets gate node joining:
#
#   bootstrap-token  (24h TTL)   needed by both CP and worker joins
#                                 — kubeadm join uses it to fetch cluster-info
#   kubeadm-certs    (2h TTL)    needed only by CP joins
#                                 — encrypts the upload-certs CA bundle so new
#                                 CPs can decrypt with --certificate-key
#
# On the FIRST apply, both are created by cp[0]'s `kubeadm init --upload-certs`.
# After that, neither is automatically refreshed by anything. So a `cp_count =
# 5` change two weeks later would fail mid-cloud-init when the new CPs try to
# decrypt the (long-since-deleted) kubeadm-certs Secret.
#
# This null_resource runs `kubeadm token create $TOKEN` and `kubeadm init phase
# upload-certs` on a CP via SSH on every apply. Both commands are idempotent and
# reset the TTLs back to 24h / 2h respectively, with the same token + key values
# that are already in terraform state (so cloud-init's pre-rendered values still
# match). On the very first apply (cluster doesn't exist yet) the SSH fails —
# the script catches that and exits 0 so cp[0] can proceed with its bootstrap.

resource "null_resource" "refresh_join_secrets" {
  # Re-run whenever node counts change (i.e. every scale-up/down). That covers
  # the only case when fresh join secrets actually matter. Avoids noisy "always
  # replaced" diffs in plan output for unrelated applies.
  #
  # `force_refresh_join_secrets` is the manual escape hatch: flip the var, apply,
  # flip back. Needed when the bootstrap token expires from neglect (>24h since
  # last apply) and the operator wants to re-create a tainted node without
  # changing cp_count/worker_count.
  triggers = {
    cp_count      = var.cp_count
    worker_count  = var.worker_count
    force_refresh = var.force_refresh_join_secrets
  }

  provisioner "local-exec" {
    interpreter = ["bash", "-c"]
    command     = <<-EOT
      set -euo pipefail

      LB_IP="${hcloud_load_balancer.k8s_api.ipv4}"
      SSH_PORT="${var.kube_api_lb_ssh_port}"
      KEY="${pathexpand(var.ssh_private_key_path)}"
      BT_ID="${random_password.bt_id.result}"
      BT_TOKEN="${local.bootstrap_token}"
      CERT_KEY="${local.cert_key}"

      # `StrictHostKeyChecking=accept-new` (rather than `no`): SSH accepts a
      # new host key on first contact, but REJECTS if it ever changes — so
      # MITM after first contact is detected. We can't depend on
      # `local_file.ssh_config` here because that would create a TF cycle
      # (server → ssh_config → refresh → server). known_hosts gets populated
      # for real by `null_resource.user_known_hosts` later in the apply.
      ssh_cmd() {
        ssh -p "$SSH_PORT" -i "$KEY" \
          -o StrictHostKeyChecking=accept-new -o BatchMode=yes \
          -o ConnectTimeout=10 -o ConnectionAttempts=1 \
          root@"$LB_IP" "$@"
      }

      # First-apply detection: if the cluster doesn't exist yet, ssh to the LB
      # fails (no targets healthy). That's fine — exit 0 so cp[0] can bootstrap.
      if ! ssh_cmd "kubectl --kubeconfig=/etc/kubernetes/admin.conf get --raw /healthz" >/dev/null 2>&1; then
        echo "cluster not yet reachable; skipping refresh (first apply or transient)"
        exit 0
      fi

      echo "==> refreshing bootstrap token (id=$BT_ID, 24h TTL)"
      ssh_cmd "
        kubeadm token delete '$BT_ID' >/dev/null 2>&1 || true
        kubeadm token create '$BT_TOKEN' --ttl 24h0m0s \
          --description 'auto-refreshed by terraform' >/dev/null
      "

      echo "==> refreshing kubeadm-certs Secret (2h TTL) for CP scale-up"
      ssh_cmd "
        kubeadm init phase upload-certs --upload-certs \
          --certificate-key='$CERT_KEY' >/dev/null
      "

      echo "join secrets refreshed; CP and worker scale-up will succeed"
    EOT
  }
}
