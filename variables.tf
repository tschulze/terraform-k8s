variable "hcloud_token" {
  type        = string
  description = "Hetzner Cloud API token (read-write). 64 characters."
  sensitive   = true
  validation {
    condition     = length(var.hcloud_token) == 64
    error_message = "Hetzner Cloud API tokens are 64 characters."
  }
}

variable "cluster_name" {
  type        = string
  description = "Name prefix for all resources."
  default     = "k8s"
  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{1,40}$", var.cluster_name))
    error_message = "cluster_name must start with a lowercase letter and contain only lowercase letters, digits, hyphens (max 41 chars)."
  }
}

variable "location" {
  type        = string
  description = "Hetzner Cloud location code."
  default     = "nbg1"
  validation {
    condition     = contains(["fsn1", "nbg1", "hel1", "hil", "ash", "sin"], var.location)
    error_message = "location must be one of fsn1, nbg1, hel1, hil, ash, sin."
  }
}

variable "network_zone" {
  type        = string
  description = "Hetzner Cloud network zone. Must match the chosen location's zone."
  default     = "eu-central"
  validation {
    condition     = contains(["eu-central", "us-east", "us-west", "ap-southeast"], var.network_zone)
    error_message = "network_zone must be one of eu-central, us-east, us-west, ap-southeast."
  }
}

variable "os_image" {
  type        = string
  description = "Hetzner OS image (Debian latest stable). Verify availability with: hcloud image list --type system | grep debian"
  default     = "debian-13"
  validation {
    condition     = can(regex("^debian-(12|13)$", var.os_image))
    error_message = "os_image must be debian-12 or debian-13."
  }
}

variable "cp_count" {
  type        = number
  description = "Number of control-plane nodes (odd for etcd quorum)."
  default     = 3
  validation {
    condition     = var.cp_count >= 1 && var.cp_count <= 7 && var.cp_count % 2 == 1
    error_message = "cp_count must be an odd number between 1 and 7."
  }
}

variable "worker_count" {
  type        = number
  description = "Number of worker nodes."
  default     = 3
  validation {
    condition     = var.worker_count >= 0 && var.worker_count <= 50
    error_message = "worker_count must be between 0 and 50."
  }
}

variable "cp_server_type" {
  type        = string
  description = "Hetzner server type for control-plane nodes (e.g. cx23, cpx31, ccx13, cax21)."
  default     = "cx23"
  validation {
    condition     = can(regex("^(cx|cpx|ccx|cax)[0-9]+$", var.cp_server_type))
    error_message = "cp_server_type must match Hetzner server type pattern."
  }
}

variable "worker_server_type" {
  type        = string
  description = "Hetzner server type for worker nodes. Default cx33 (4 vCPU / 8 GiB) — Rook-Ceph wants ≥8 GiB per OSD node; cx23 (4 GiB) is too small."
  default     = "cx33"
  validation {
    condition     = can(regex("^(cx|cpx|ccx|cax)[0-9]+$", var.worker_server_type))
    error_message = "worker_server_type must match Hetzner server type pattern."
  }
}

variable "ssh_public_key_path" {
  type        = string
  description = "Path to SSH public key uploaded to Hetzner for root login."
  default     = "~/.ssh/id_ed25519_hetzner.pub"
}

variable "ssh_private_key_path" {
  type        = string
  description = "Path to SSH private key used by Terraform to scp kubeconfig from cp[0]."
  sensitive   = true
  default     = "~/.ssh/id_ed25519_hetzner"
}

variable "network_cidr" {
  type        = string
  description = "Hetzner Cloud Network subnet CIDR. MUST NOT overlap with pod_cidr_v4 or service_cidr_v4."
  default     = "10.0.0.0/24"
  validation {
    condition     = can(cidrhost(var.network_cidr, 0))
    error_message = "network_cidr must be a valid IPv4 CIDR."
  }
}

variable "pod_cidr_v4" {
  type        = string
  description = "IPv4 pod CIDR (Calico IPAM)."
  default     = "10.95.0.0/16"
  validation {
    condition     = can(cidrhost(var.pod_cidr_v4, 0))
    error_message = "pod_cidr_v4 must be a valid IPv4 CIDR."
  }
}

variable "pod_cidr_v6" {
  type        = string
  description = "IPv6 pod CIDR (Calico IPAM, NAT-out enabled)."
  default     = "2001:db8:95::/56"
}

variable "service_cidr_v4" {
  type        = string
  description = "IPv4 Kubernetes Service CIDR."
  default     = "10.96.0.0/16"
  validation {
    condition     = can(cidrhost(var.service_cidr_v4, 0))
    error_message = "service_cidr_v4 must be a valid IPv4 CIDR."
  }
}

variable "service_cidr_v6" {
  type        = string
  description = "IPv6 Kubernetes Service CIDR."
  default     = "2001:db8:96::/112"
}

variable "kubernetes_version" {
  type        = string
  description = "Kubernetes minor version (e.g. 1.35) used for apt repo and package pin."
  default     = "1.35"
  validation {
    condition     = can(regex("^1\\.[0-9]+$", var.kubernetes_version))
    error_message = "kubernetes_version must look like 1.35."
  }
}

variable "cluster_dns_zone" {
  type        = string
  description = "DNS zone managed by DigitalOcean DNS that Terraform will populate with cluster records (e.g. 'k8s.example.com'). Empty = skip DNS automation; you'll add records manually wherever your DNS lives. Requires the zone to already exist in DigitalOcean (free) and the parent domain to delegate this subdomain to DigitalOcean's nameservers (ns1/ns2/ns3.digitalocean.com)."
  default     = ""
  validation {
    # Reject obvious typos (uppercase, double-dot, slashes, leading/trailing dot)
    # before they reach the DigitalOcean API and produce a confusing apply
    # failure. RFC 1035 label charset, dot-separated, 1-253 chars total.
    condition     = var.cluster_dns_zone == "" || can(regex("^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\\.)+[a-z]{2,63}$", var.cluster_dns_zone))
    error_message = "cluster_dns_zone must be a lowercase DNS name (RFC 1035 labels separated by dots, e.g. 'k8s.example.com'). Empty disables DNS automation."
  }
}

variable "digitalocean_token" {
  type        = string
  description = "DigitalOcean API token, scoped to Domain read+update only. Generate at DigitalOcean Cloud Panel → API → Tokens with Custom Scopes (Domain: read, update). Only used when cluster_dns_zone is set."
  default     = ""
  sensitive   = true
}

variable "services_lb_type" {
  type        = string
  description = "Hetzner Load Balancer type for the Traefik (HTTP/HTTPS) services LB."
  default     = "lb11"
}

variable "kube_api_lb_type" {
  type        = string
  description = "Hetzner Load Balancer type for the kube-API + SSH-jump LB."
  default     = "lb11"
}

variable "kube_api_lb_ssh_port" {
  type        = number
  description = "Public listen port on the LB for SSH jump host (forwards to CP node :22)."
  default     = 2222
}

variable "tigera_operator_chart_version" {
  type        = string
  description = "Tigera operator (Calico) Helm chart version."
  default     = "v3.31.5"
}

variable "kubelet_csr_approver_chart_version" {
  type        = string
  description = "Helm chart version for postfinance/kubelet-csr-approver. Auto-approves kubelet serving-cert CSRs (paired with serverTLSBootstrap: true in kubeadm-config) so we can drop --kubelet-insecure-tls from metrics-server."
  default     = "1.2.14"
}

variable "ceph_osd_volume_size_gb" {
  type        = number
  description = "Size (GB) of the raw Hetzner Cloud Volume attached per worker for Ceph OSD. Recommended 100 for production; override to 10 in terraform.tfvars to start cheap."
  default     = 100
  validation {
    condition     = var.ceph_osd_volume_size_gb >= 10 && var.ceph_osd_volume_size_gb <= 10240
    error_message = "ceph_osd_volume_size_gb must be between 10 and 10240."
  }
}

variable "traefik_node_port_http" {
  type        = number
  description = "NodePort on each node where Traefik listens for HTTP. The services LB forwards :80 → this port."
  default     = 30080
  validation {
    condition     = var.traefik_node_port_http >= 30000 && var.traefik_node_port_http <= 32767
    error_message = "traefik_node_port_http must be in the Kubernetes NodePort range 30000-32767."
  }
}

variable "traefik_node_port_https" {
  type        = number
  description = "NodePort on each node where Traefik listens for HTTPS. The services LB forwards :443 → this port."
  default     = 30443
  validation {
    condition     = var.traefik_node_port_https >= 30000 && var.traefik_node_port_https <= 32767
    error_message = "traefik_node_port_https must be in the Kubernetes NodePort range 30000-32767."
  }
}

variable "etcd_retired_encryption_keys" {
  type = list(object({
    name   = string
    secret = string
  }))
  description = <<-EOT
    Additional decrypt-only AES-CBC keys for etcd. Used during key rotation: place the
    PREVIOUS active key here so the apiserver can still decrypt existing data while the
    new (Terraform-generated) key writes new data. After re-encryption is complete,
    remove the entry from this list. Each `secret` is the base64-encoded 32-byte key
    (the `.b64_std` form of `random_id.encryption_key`).
  EOT
  default     = []
}

variable "etcd_snapshot_age_recipient" {
  type        = string
  description = "age public key (e.g. 'age1abc...') used to encrypt the daily etcd snapshots written to /var/backups/etcd/ on each control-plane node. REQUIRED. An etcd snapshot is the entire cluster state with every Secret value decrypted (etcdctl reads via the client API which decrypts on read). Without encryption a single rooted CP for an hour leaks every Secret in the 14-day retention window. Generate with: age-keygen -o ~/.config/sops/age/keys.txt"
  validation {
    condition     = can(regex("^age1[a-z0-9]{58}$", var.etcd_snapshot_age_recipient))
    error_message = "etcd_snapshot_age_recipient must be a valid age recipient (^age1[a-z0-9]{58}$). Empty is no longer accepted — plaintext snapshots leak every cluster Secret."
  }
}

variable "admin_users" {
  type        = list(string)
  description = "Usernames to provision personal cluster-admin kubeconfigs for. Each gets a 1y client cert via the cluster CSR API + a ClusterRoleBinding to cluster-admin. Outputs to secrets/admin-<name>-{v4,v6}.conf."
  default     = []
  validation {
    condition     = alltrue([for u in var.admin_users : can(regex("^[a-z][a-z0-9-]{0,30}$", u))])
    error_message = "Each admin_users name must match ^[a-z][a-z0-9-]{0,30}$ (names flow into shell commands and kubectl object names — anything else is a shell-injection vector)."
  }
}

variable "sealed_secrets_chart_version" {
  type        = string
  description = "Helm chart version for bitnami-labs/sealed-secrets (in-cluster Secret encryption controller)."
  default     = "2.18.5"
}

variable "sealed_secrets_age_identity_path" {
  type        = string
  description = "Path to the age identity file (private key) used to decrypt secrets/sealed-secrets-master.key.yaml.age at apply time. Operator-local, never committed. Generate with: age-keygen -o ~/.config/sops/age/keys.txt"
  default     = "~/.config/sops/age/keys.txt"
  sensitive   = true
}

variable "argocd_chart_version" {
  type        = string
  description = "Helm chart version for argoproj/argo-cd."
  default     = "9.5.4"
}

variable "argocd_hostname" {
  type        = string
  description = "Hostname for the Argo CD UI HTTPRoute (e.g. 'argocd.example.com'). Empty = no HTTPRoute, ClusterIP only — access via 'kubectl -n argocd port-forward svc/argocd-server 8080:80'."
  default     = ""
}

variable "argocd_repo_url" {
  type        = string
  description = "SSH URL of the gitops repo for Argo CD's App-of-Apps bootstrap (e.g. 'git@github.com:owner/k8s-gitops.git'). Empty = skip auto-bootstrap; you'll connect repos and create Applications manually in the UI."
  default     = ""
  validation {
    # Restrict to safe SSH-URL shapes — value flows into a single-quoted
    # bash literal in helm-argocd.tf's kubectl-create-secret command. A
    # value containing `'` would shell-break out.
    condition     = var.argocd_repo_url == "" || can(regex("^(git@|ssh://git@|https://)[A-Za-z0-9._:/~/-]+\\.git$", var.argocd_repo_url))
    error_message = "argocd_repo_url must be a plain git URL (git@host:owner/repo.git, ssh://git@host/owner/repo.git, or https://host/owner/repo.git) and end in .git. No quotes, semicolons, or shell metacharacters."
  }
}

variable "argocd_repo_ssh_private_key_path" {
  type        = string
  description = "Path to the SSH private key (deploy key) for argocd_repo_url. Defaults to secrets/argocd-deploy in the project — generate with: ssh-keygen -t ed25519 -f secrets/argocd-deploy -N '' -C 'argocd@<cluster>'. The matching .pub goes into the repo's GitHub Settings → Deploy keys."
  default     = "secrets/argocd-deploy"
  sensitive   = true
}

variable "argocd_root_app_path" {
  type        = string
  description = "Path inside argocd_repo_url that contains child Application/AppProject manifests for the App-of-Apps pattern. The root Application syncs this directory; everything else is managed in git from there."
  default     = "argocd/apps"
}

variable "argocd_root_app_revision" {
  type        = string
  description = "Branch / tag / commit in argocd_repo_url that the root Application tracks."
  default     = "main"
}

