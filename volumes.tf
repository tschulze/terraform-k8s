resource "hcloud_volume" "osd" {
  count    = var.worker_count
  name     = "${var.cluster_name}-osd-${count.index}"
  size     = var.ceph_osd_volume_size_gb
  location = var.location
  format   = null
}
