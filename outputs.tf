output "kubeconfig_path" {
  description = "Path to the cluster kubeconfig (relative to module root)."
  value       = local.kubeconfig_path
}

output "api_lb_private_ipv4" {
  description = "Cloud Network IPv4 of the kube-API LB (controlPlaneEndpoint for kubelet/kubectl inside the network)."
  value       = local.api_lb_private_ip
}

output "services_lb_private_ipv4" {
  description = "Internal IPv4 of the services (HTTP/HTTPS) LB on the Cloud Network."
  value       = local.services_lb_private_ip
}

output "services_lb_public_ipv4" {
  description = "Public IPv4 of the services (HTTP/HTTPS) LB."
  value       = hcloud_load_balancer.services.ipv4
}

output "services_lb_public_ipv6" {
  description = "Public IPv6 of the services (HTTP/HTTPS) LB."
  value       = hcloud_load_balancer.services.ipv6
}

output "cp_public_ipv6" {
  description = "Public IPv6 of each control-plane node (first usable host of each /64 from Hetzner). Nodes have no public IPv4; reach them via the LB jump host."
  value       = [for s in hcloud_server.cp : cidrhost(s.ipv6_network, 1)]
}

output "worker_public_ipv6" {
  description = "Public IPv6 of each worker node (first usable host of each /64). Nodes have no public IPv4; reach them via the LB jump host."
  value       = [for s in hcloud_server.worker : cidrhost(s.ipv6_network, 1)]
}

output "cp_private_ips" {
  description = "Cloud Network IPs of control-plane nodes."
  value       = local.cp_node_ips
}

output "worker_private_ips" {
  description = "Cloud Network IPs of worker nodes."
  value       = local.worker_node_ips
}

output "kube_api_lb_ipv4" {
  description = "Public IPv4 of the kube-API + SSH-jump LB."
  value       = hcloud_load_balancer.k8s_api.ipv4
}

output "kube_api_lb_ipv6" {
  description = "Public IPv6 of the kube-API + SSH-jump LB."
  value       = hcloud_load_balancer.k8s_api.ipv6
}

output "ssh_cp0" {
  description = "Shortcut SSH command (via LB jump host)."
  value       = length(hcloud_server.cp) > 0 ? "ssh ${local.cp_node_names[0]}" : ""
}
