# DigitalOcean DNS records — managed when var.cluster_dns_zone is set. The zone
# itself must already exist in DigitalOcean (free); we look it up by name.
#
# Records created (all with 300s TTL so changes propagate fast):
#   - apex (@)        A/AAAA → services LB    (e.g. k8s.example.com)
#   - wildcard (*)    A/AAAA → services LB    (e.g. argocd.k8s.example.com, foo.k8s...)
#   - api             A/AAAA → kube-API LB    (kubectl/SSH-jump convenience name)
#
# Wildcard does NOT cover the apex (DNS rule), so the apex gets its own pair.

locals {
  dns_enabled = var.cluster_dns_zone != ""
}

data "digitalocean_domain" "cluster" {
  count = local.dns_enabled ? 1 : 0
  name  = var.cluster_dns_zone
}

resource "digitalocean_record" "apex_a" {
  count  = local.dns_enabled ? 1 : 0
  domain = data.digitalocean_domain.cluster[0].name
  type   = "A"
  name   = "@"
  value  = hcloud_load_balancer.services.ipv4
  ttl    = 300
}

resource "digitalocean_record" "apex_aaaa" {
  count  = local.dns_enabled ? 1 : 0
  domain = data.digitalocean_domain.cluster[0].name
  type   = "AAAA"
  name   = "@"
  value  = hcloud_load_balancer.services.ipv6
  ttl    = 300
}

resource "digitalocean_record" "wildcard_a" {
  count  = local.dns_enabled ? 1 : 0
  domain = data.digitalocean_domain.cluster[0].name
  type   = "A"
  name   = "*"
  value  = hcloud_load_balancer.services.ipv4
  ttl    = 300
}

resource "digitalocean_record" "wildcard_aaaa" {
  count  = local.dns_enabled ? 1 : 0
  domain = data.digitalocean_domain.cluster[0].name
  type   = "AAAA"
  name   = "*"
  value  = hcloud_load_balancer.services.ipv6
  ttl    = 300
}

resource "digitalocean_record" "api_a" {
  count  = local.dns_enabled ? 1 : 0
  domain = data.digitalocean_domain.cluster[0].name
  type   = "A"
  name   = "api"
  value  = hcloud_load_balancer.k8s_api.ipv4
  ttl    = 300
}

resource "digitalocean_record" "api_aaaa" {
  count  = local.dns_enabled ? 1 : 0
  domain = data.digitalocean_domain.cluster[0].name
  type   = "AAAA"
  name   = "api"
  value  = hcloud_load_balancer.k8s_api.ipv6
  ttl    = 300
}
