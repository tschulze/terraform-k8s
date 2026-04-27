provider "hcloud" {
  token = var.hcloud_token
}

provider "digitalocean" {
  token = var.digitalocean_token
}

provider "kubernetes" {
  config_path = local.kubeconfig_path
}

provider "helm" {
  kubernetes {
    config_path = local.kubeconfig_path
  }
}
