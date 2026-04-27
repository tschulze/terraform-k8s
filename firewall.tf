resource "hcloud_firewall" "nodes" {
  name = "${var.cluster_name}-nodes"

  apply_to {
    label_selector = "cluster=${var.cluster_name}"
  }

  # ALLOWLIST FIREWALL — Hetzner Cloud Firewall is default-deny on inbound
  # traffic ONCE AT LEAST ONE INBOUND RULE EXISTS. From the docs:
  # > "If the firewall has at least one rule, all other traffic of the
  # >  same direction is blocked."
  # https://docs.hetzner.com/cloud/firewalls/faq/
  #
  # Apply-side: applies to PUBLIC interfaces only. Traffic on the Hetzner
  # Cloud Network (10.0.0.0/24) is NOT filtered by CFW — pod traffic, etcd,
  # kubelet etc. on private interfaces is unrestricted between cluster nodes.
  #
  # The single ICMP rule below means: all other inbound TCP/UDP on the
  # public IPv4/IPv6 of every node (kubelet :10250, etcd :2379-2381,
  # kube-proxy :10249, NodePort range 30000-32767, apiserver :6443 except
  # via the LB → private path) is implicitly DENIED. Verify with:
  #   nmap -sT -p- <node-public-ipv4>
  rule {
    direction   = "in"
    protocol    = "icmp"
    source_ips  = ["0.0.0.0/0", "::/0"]
    description = "ICMP from anywhere (default-denies all other inbound)"
  }
}
