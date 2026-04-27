# Two Hetzner Load Balancers in the Cloud Network:
#   k8s_api   .2  → kube-API (6443) + SSH-jump (2222) → control-plane backends
#   services  .3  → HTTP (80) + HTTPS (443) → all nodes' Traefik NodePort
#
# Both joined to the Cloud Network with private IPs explicitly pinned (away from the
# node IP range .4-.9). Backends reached via Cloud Network (use_private_ip = true).

# ---- k8s API + SSH jump ----

resource "hcloud_load_balancer" "k8s_api" {
  name               = "${var.cluster_name}-api"
  load_balancer_type = var.kube_api_lb_type
  location           = var.location

  labels = {
    cluster = var.cluster_name
  }
}

resource "hcloud_load_balancer_network" "k8s_api" {
  load_balancer_id = hcloud_load_balancer.k8s_api.id
  subnet_id        = hcloud_network_subnet.kubenet.id
  ip               = local.api_lb_private_ip
}

resource "hcloud_load_balancer_target" "k8s_api" {
  type             = "label_selector"
  load_balancer_id = hcloud_load_balancer.k8s_api.id
  label_selector   = "cluster=${var.cluster_name},role=control-plane"
  use_private_ip   = true

  depends_on = [hcloud_load_balancer_network.k8s_api]
}

resource "hcloud_load_balancer_service" "k8s_api" {
  load_balancer_id = hcloud_load_balancer.k8s_api.id
  protocol         = "tcp"
  listen_port      = 6443
  destination_port = 6443

  health_check {
    protocol = "tcp"
    port     = 6443
    interval = 15
    timeout  = 10
    retries  = 3
  }
}

resource "hcloud_load_balancer_service" "k8s_ssh_jump" {
  load_balancer_id = hcloud_load_balancer.k8s_api.id
  protocol         = "tcp"
  listen_port      = var.kube_api_lb_ssh_port
  destination_port = 22

  health_check {
    protocol = "tcp"
    port     = 22
    interval = 15
    timeout  = 10
    retries  = 3
  }
}

# ---- Traefik HTTP/HTTPS services ----

resource "hcloud_load_balancer" "services" {
  name               = "${var.cluster_name}-svc"
  load_balancer_type = var.services_lb_type
  location           = var.location

  labels = {
    cluster = var.cluster_name
  }
}

resource "hcloud_load_balancer_network" "services" {
  load_balancer_id = hcloud_load_balancer.services.id
  subnet_id        = hcloud_network_subnet.kubenet.id
  ip               = local.services_lb_private_ip
}

resource "hcloud_load_balancer_target" "services" {
  type             = "label_selector"
  load_balancer_id = hcloud_load_balancer.services.id
  # Workers only — Traefik pods can't schedule on CPs (control-plane taint),
  # so LB health checks would fail for CPs anyway.
  label_selector = "cluster=${var.cluster_name},role=worker"
  use_private_ip = true

  depends_on = [hcloud_load_balancer_network.services]
}

resource "hcloud_load_balancer_service" "http" {
  load_balancer_id = hcloud_load_balancer.services.id
  protocol         = "tcp"
  listen_port      = 80
  destination_port = var.traefik_node_port_http

  health_check {
    protocol = "tcp"
    port     = var.traefik_node_port_http
    interval = 15
    timeout  = 10
    retries  = 3
  }
}

resource "hcloud_load_balancer_service" "https" {
  load_balancer_id = hcloud_load_balancer.services.id
  protocol         = "tcp"
  listen_port      = 443
  destination_port = var.traefik_node_port_https

  health_check {
    protocol = "tcp"
    port     = var.traefik_node_port_https
    interval = 15
    timeout  = 10
    retries  = 3
  }
}
