resource "hcloud_ssh_key" "admin" {
  name       = "${var.cluster_name}-admin"
  public_key = local.ssh_public_key_openssh
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

