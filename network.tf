resource "hcloud_ssh_key" "admin" {
  name       = "${var.cluster_name}-admin"
  public_key = trimspace(file(pathexpand(var.ssh_public_key_path)))
}

# IPv4 CIDR overlap check. HCL has no `cidroverlap` builtin, so we convert
# each CIDR's [first, last] host range to a 32-bit integer range and apply
# the standard interval-intersection test (a.start <= b.end && b.start <= a.end).
# Catches the kind of typo that costs an hour of debugging when kubeadm comes
# up but pods can't talk to the apiserver because two CIDRs claim the same IPs.
locals {
  _v4_cidrs = {
    network_cidr    = var.network_cidr
    pod_cidr_v4     = var.pod_cidr_v4
    service_cidr_v4 = var.service_cidr_v4
  }
  _v4_ranges = {
    for k, c in local._v4_cidrs : k => {
      start = (
        tonumber(split(".", cidrhost(c, 0))[0]) * 16777216 +
        tonumber(split(".", cidrhost(c, 0))[1]) * 65536 +
        tonumber(split(".", cidrhost(c, 0))[2]) * 256 +
        tonumber(split(".", cidrhost(c, 0))[3])
      )
      end = (
        tonumber(split(".", cidrhost(c, -1))[0]) * 16777216 +
        tonumber(split(".", cidrhost(c, -1))[1]) * 65536 +
        tonumber(split(".", cidrhost(c, -1))[2]) * 256 +
        tonumber(split(".", cidrhost(c, -1))[3])
      )
    }
  }
  _v4_pairs = [
    ["network_cidr", "pod_cidr_v4"],
    ["network_cidr", "service_cidr_v4"],
    ["pod_cidr_v4", "service_cidr_v4"],
  ]
  _v4_overlap_pairs = [
    for pair in local._v4_pairs :
    "${pair[0]} (${local._v4_cidrs[pair[0]]}) overlaps ${pair[1]} (${local._v4_cidrs[pair[1]]})"
    if local._v4_ranges[pair[0]].start <= local._v4_ranges[pair[1]].end &&
    local._v4_ranges[pair[1]].start <= local._v4_ranges[pair[0]].end
  ]
}

resource "terraform_data" "cidr_overlap_check" {
  lifecycle {
    precondition {
      condition     = length(local._v4_overlap_pairs) == 0
      error_message = "Overlapping IPv4 CIDRs detected — fix terraform.tfvars before applying:\n  ${join("\n  ", local._v4_overlap_pairs)}"
    }
  }
}

resource "hcloud_network" "kubenet" {
  name     = "${var.cluster_name}-net"
  ip_range = var.network_cidr
}

resource "hcloud_network_subnet" "kubenet" {
  network_id   = hcloud_network.kubenet.id
  type         = "cloud"
  network_zone = var.network_zone
  ip_range     = var.network_cidr
}

# Render the NetworkPolicy starter template so its ipBlock CIDRs track
# var.network_cidr automatically — earlier this was a static .yaml with
# 10.0.0.0/24 hard-coded plus a comment "match var.network_cidr", which silently
# rotted whenever an operator overrode the default.
resource "local_file" "networkpolicy_example" {
  filename        = "${path.module}/examples/networkpolicy-template.yaml"
  file_permission = "0644"
  content = templatefile("${path.module}/examples/networkpolicy-template.yaml.tftpl", {
    network_cidr = var.network_cidr
  })
}

