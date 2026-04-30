# terraform-k8s

Greenfield Hetzner Cloud Kubernetes cluster provisioned with Terraform.

- HA control plane (3 CP + 3 worker by default; both adjustable via variables)
- Kubernetes `1.35` (configurable via `var.kubernetes_version`)
- Debian latest stable (default `debian-13`) on each node — first-boot apt upgrade + auto-reboot for kernel patches
- kubeadm bootstrap with declarative token + cert key (no SSH dance)
- Two Hetzner Load Balancers in the Cloud Network:
  - `k8s_api` LB (`10.0.0.2`) → kube-API (6443) + SSH-jump (2222) → CP nodes
  - `services` LB (`10.0.0.3`) → HTTP/HTTPS (80/443) → worker NodePorts (Traefik)
- Calico via the Tigera operator, dual-stack (`10.95.0.0/16` + `2001:db8:95::/56`)
- Traefik with Gateway API for HTTP/HTTPS ingress (NodePort-fronted by the services LB)
- Rook-Ceph operator + cluster (one raw Hetzner Cloud Volume per worker, default 100 GB)
- cert-manager + ClusterIssuers (when an ACME email is configured)
- Trivy operator (vulnerability + CIS compliance), Falco (runtime IDS)
- Sealed Secrets controller (commit encrypted Secret manifests to git)
- Pod Security Admission `restricted` enforcement cluster-wide (system namespaces exempt)
- Kyverno admission webhook + 5 starter ClusterPolicies (image tags, registry allowlist, auto default-deny NetworkPolicy, resource limits, no default SA)
- Argo CD (gitops deployment) — UI exposed via Traefik HTTPRoute when `var.argocd_hostname` is set
- metrics-server (`kubectl top`)
- Velero + Vector (audit log shipping) — both opt-in, conditional on S3 vars
- Personal cluster-admin kubeconfigs via the cluster CSR API (`var.admin_users`)

## Prerequisites

1. **Hetzner Cloud project** with API token (read+write). Put it in `terraform.tfvars` (gitignored) or export `TF_VAR_hcloud_token=...`.
2. **SSH key pair** at `~/.ssh/id_ed25519_hetzner` and `~/.ssh/id_ed25519_hetzner.pub`. Generate with:
   ```
   ssh-keygen -t ed25519 -f ~/.ssh/id_ed25519_hetzner
   ```
3. **Tools**: `terraform >= 1.6`, `kubectl`, `helm`. `hcloud` CLI optional for verification.
4. **age identity** at `~/.config/sops/age/keys.txt` — see *Operator security model* below.

## Operator security model

The operator's laptop is part of the trust boundary. Treat the following two files as **crown-jewel-equivalent** — losing or leaking either compromises the cluster:

### `terraform.tfstate` (this directory)

State holds the cluster CA private key (RSA-4096), the Hetzner API token, the etcd encryption-at-rest key, the kubeadm bootstrap token, and the kubeadm certificate key. With state in hand an attacker can: sign arbitrary admin kubeconfigs, decrypt every Secret currently in etcd, MITM the apiserver, or drive Hetzner Cloud API actions against the project.

- `apply.sh` chmods `terraform.tfstate*` to `0600` after every apply
- Do **not** sync this directory to iCloud/Dropbox/OneDrive — they ignore POSIX modes and replicate state at default permissions
- macOS Time Machine includes `~/` by default; either exclude this directory or accept that backups need the same physical protection as the live disk
- This module ships with **local state and no locking**. Two operators applying concurrently from different laptops will silently corrupt the state file — there's no Terraform-level mutex protecting it. If more than one operator manages the cluster, configure a remote backend (`backend "s3"` with SSE-KMS + DynamoDB locking, or Terraform Cloud workspaces with state encryption) before the second operator runs anything; the backend moves the secret to the provider's HSM/KMS and adds the lock that local state lacks

### `~/.config/sops/age/keys.txt` (your laptop)

This single age identity decrypts:

- the sealed-secrets controller master key (`secrets/sealed-secrets-master.key.yaml.age`)
- the Argo CD admin password (`secrets/argocd-admin-password.yaml.age`)
- every daily etcd snapshot on every CP (14-day retention by default)
- every `SealedSecret` ever committed to the gitops repo

There is **no recovery path** if the file is lost. There is **no rotation path** for old etcd snapshots and old SealedSecrets if the file is leaked — the historical blobs are decryptable forever by whoever has the key.

Mitigations:

- **Back it up offline.** 1Password / Bitwarden secure note, encrypted USB stick in a safe, hardware token — anywhere not on the internet. Treat it like the recovery seed for a hardware wallet.
- **Add a passphrase.** The age identity itself can be `age -p`-encrypted before being placed at `~/.config/sops/age/keys.txt`; you'll be prompted on every apply, but a stolen disk is no longer a stolen identity.
- **Don't share between operators.** Each operator should have their own identity; encrypt blobs to all recipients in parallel (`age -r age1op1... -r age1op2...`). Removing an operator means rotating the controller master key + the Argo password (and ideally the etcd encryption key) so their copy stops being load-bearing.

The tfstate and the age identity together are equivalent to root on the cluster. Either alone gives partial control. Both stolen = full game-over with no audit trail.

### Network threat model — single-firewall posture

Every node has both a public IPv4 and a public IPv6 (`hcloud_server.public_net.ipv{4,6}_enabled = true`). The control-plane components — apiserver, controller-manager, scheduler — bind on `0.0.0.0`, which means they're listening on the public NICs as well as the Cloud Network. Same for `etcd`'s metrics endpoint (`listen-metrics-urls: http://0.0.0.0:2381`) and `kube-proxy`'s `metricsBindAddress: 0.0.0.0:10249`.

**The only thing standing between the public internet and those listeners is the Hetzner Cloud Firewall** (`firewall.tf`), which is configured allowlist-style: a single inbound ICMP rule, which makes the firewall default-deny everything else (per Hetzner's docs: *"If the firewall has at least one rule, all other traffic of the same direction is blocked"*). If the firewall is detached, mis-applied, or its label-selector stops matching the nodes (e.g. you change `cluster_name` on existing nodes), the apiserver becomes a public 6443 listener with no second layer.

Practical consequences:

- Verify the firewall is attached to every node after every apply. The label selector is `cluster=${var.cluster_name}`; any new server resource that forgets to set that label drops out of firewall coverage. `nmap -sT -p- <node-public-ipv4>` should show only ICMP responses, no TCP services.
- Don't change `cluster_name` on a running cluster without re-checking firewall coverage.
- The Hetzner CFW is enforced at the hypervisor; it's not bypassable from inside the VM. But it has no logging — you cannot tell from cluster-side audit logs whether a connection attempt was firewalled or simply never tried.
- Pod-to-pod traffic on the Cloud Network is **not** firewalled by CFW (it's a public-NIC-only filter). NetworkPolicy + Calico WireGuard provide the in-cluster equivalent (see `examples/networkpolicy-template.yaml.tftpl` for the per-namespace default-deny starter).

Tightening this — switching every component's `bind-address` to the Cloud Network NIC only — is a tractable but separate change: each component would need to learn the auto-assigned private IP at cloud-init time (the same `__NODE_PRIVATE_IP__` substitution we already do for `localAPIEndpoint.advertiseAddress`). Tracked as a follow-up; the current single-firewall posture is acceptable as long as the CFW invariants above hold.

## Cost (running, defaults, Nuremberg, EUR — gross)

Default topology: 3× cx23 control-plane + 3× cx33 worker + 3× 100 GB OSD volumes + 2× LB11.

| Item | Qty | €/month | €/hour | Subtotal/h |
|---|---|---|---|---|
| cx23 (control-plane) | 3 | 4.75  | 0.0076 | 0.0228 |
| cx33 (worker)        | 3 | 7.72  | 0.0124 | 0.0372 |
| Primary IPv4         | 6 | 0.595 | 0.0010 | 0.0057 |
| LB lb11              | 2 | 8.91  | 0.0143 | 0.0286 |
| Volume (100 GB)      | 3 | 6.81  | 0.0093 | 0.0280 |

≈ **€0.122/hour ≈ €79/month** at full size (monthly is capped lower than 730 × hourly — pay whichever is smaller).

**Cheap-start option** (override `ceph_osd_volume_size_gb = 10` in `terraform.tfvars`): drops volume cost by ~10×, total comes in around **€0.097/hour ≈ €61/month**. Hetzner volumes have a 10 GB minimum, so that's the floor.

### Server-type alternatives

The `cx-3` line (Cost-Optimized, mixed Intel/AMD, no vendor guarantee) is the cheapest tier Hetzner offers — switching server types in either direction costs more:

| Worker SKU | vCPU | RAM | Disk | Arch | €/mo | vs cx33 |
|---|---|---|---|---|---|---|
| **cx33** (default) | 4 | 8 | 80 GB | x86 mixed | 7.72 | — |
| cax21 (ARM) | 4 | 8 | 80 GB | arm64 | 9.51 | +€1.79 |
| cpx32 (guaranteed AMD, gen-2) | 4 | 8 | 160 GB | x86 AMD | 16.65 | +€8.93 |
| cpx31 (guaranteed AMD, gen-1) | 4 | 8 | 160 GB | x86 AMD | 20.81 | +€13.09 |
| cx43 (one tier larger) | 8 | 16 | 160 GB | x86 mixed | 14.27 | +€6.55 |

The Performance line (`cpx`) is ~2× the cost for similar specs — its value is guaranteed-recent AMD silicon and lower noisy-neighbor risk, which doesn't move the needle for a small homelab cluster. ARM (`cax`) is a few EUR more but charts ship multi-arch; viable if you want to experiment.

Prices are gross / VAT-inclusive at Nuremberg, fetched live from the Hetzner Cloud API on 2026-04-26 — re-check at <https://www.hetzner.com/cloud/> or via the API (`/v1/server_types`, `/v1/load_balancer_types`, `/v1/pricing`) before relying on them.

## Apply

```bash
# Optional: confirm Debian image is available in your project
hcloud image list --type system | grep debian

# Copy the example, fill in the token (or export TF_VAR_hcloud_token=)
cp terraform.tfvars.example terraform.tfvars
$EDITOR terraform.tfvars

terraform init
terraform plan
terraform apply
```

After apply completes, the kubeconfig is at `./secrets/admin.conf`:

```bash
export KUBECONFIG=$(terraform output -raw kubeconfig_path)
kubectl get nodes -o wide
```

If you set `admin_users = ["yourname"]`, you also get personal kubeconfigs at
`./secrets/admin-yourname-v4.conf` and `./secrets/admin-yourname-v6.conf` (same
cluster-admin permission, separate identity for audit purposes). To switch into
one quickly from anywhere, drop this helper into your shell rc and set
`TF_K8S_DIR` to the repo path on your machine:

```bash
k8s-use() {
  local user="${1:-yourname}" family="${2:-v4}" tfdir="${TF_K8S_DIR:?set TF_K8S_DIR to the repo path}"
  local rel abs
  rel=$(terraform -chdir="$tfdir" output -json admin_user_kubeconfigs 2>/dev/null \
    | jq -re ".\"$user\".\"$family\"") || { echo "no kubeconfig for $user/$family" >&2; return 1; }
  abs="$tfdir/${rel#./}"
  install -m 600 "$abs" ~/.kube/config
  echo "→ ~/.kube/config (user=$user, family=$family)"
}
```

## SSH access

Each apply writes an SSH config at `~/.ssh/config.d/k8s-<cluster_name>.conf` and
populates `~/.ssh/known_hosts` with each node's host key (pinned via Terraform).
After apply you can:

```bash
ssh k8s-cp-0     # private IP via LB jump host (port 2222)
ssh k8s-cp-0-v6  # public IPv6 of the node
ssh k8s          # the LB jump host itself
```

Strict host-key checking works out of the box (no `--insecure` flags needed).

## DNS (DigitalOcean DNS, optional)

DigitalOcean runs a free managed DNS service that — unlike Hetzner DNS or Cloudflare's free tier — accepts subdomain zones (e.g. `k8s.example.com`) without requiring you to move the apex. When `var.cluster_dns_zone` is set, terraform creates the cluster's DNS records on every apply — no manual copy/paste of LB IPs.

Records created in `<cluster_dns_zone>`:

| Name | Type | Points to |
|---|---|---|
| `@` (apex)   | A / AAAA | services LB (HTTP/HTTPS) |
| `*` (wildcard) | A / AAAA | services LB — `argocd.<zone>`, `whatever.<zone>`, etc. all resolve via Traefik |
| `api`        | A / AAAA | kube-API LB (kubectl + SSH-jump) |

### One-time setup (outside terraform)

1. **Sign up** at <https://cloud.digitalocean.com/registrations/new>. No credit card required for DNS-only use.
2. **Add the zone**: *Cloud Panel → Networking → Domains*, type `k8s.example.com` (or your subdomain), click *Add Domain*. The default 3 NS records appear — these are what your parent zone delegates to.
3. **Generate a scoped API token**: *API → Tokens → Generate New Token* with *Custom Scopes → Domain: read + update*. Copy the token (shown once). Don't grant any other scope — this token can only manage DNS, can't spin up Droplets or spend money.
4. **Delegate the subdomain** on your existing DNS by adding NS records on the parent zone:

   ```dns
   <cluster_dns_zone>.   3600   IN   NS   ns1.digitalocean.com.
   <cluster_dns_zone>.   3600   IN   NS   ns2.digitalocean.com.
   <cluster_dns_zone>.   3600   IN   NS   ns3.digitalocean.com.
   ```

5. Verify delegation worked:
   ```bash
   dig +short NS <cluster_dns_zone>
   # → expect ns1.digitalocean.com, ns2.digitalocean.com, ns3.digitalocean.com
   ```

### Wire terraform

```hcl
# terraform.tfvars (or export TF_VAR_digitalocean_token in the shell)
cluster_dns_zone   = "k8s.example.com"
digitalocean_token = "dop_v1_..."
```

`terraform apply` populates the records. Verify:

```bash
dig +short argocd.k8s.example.com
# → matches `terraform output services_lb_public_ipv4`
```

### Caveats

- **Wildcard A/AAAA does NOT mean wildcard TLS cert.** Let's Encrypt HTTP-01 issues per-hostname certs. The wildcard saves DNS work, not cert work — each new hostname still needs its own `Certificate` resource (cert-manager handles this).
- **Apex record may conflict** if you serve something at `<cluster_dns_zone>` itself (e.g. an old landing page). Either remove the existing apex record from your old DNS provider before delegating, or skip the apex by removing `digitalocean_record.apex_*` from `11-dns.tf` before applying.
- **DigitalOcean is the *DNS only*** in this setup — we don't use any of their compute, networking, or storage. The account exists solely for the DNS Console + API token.

## Pod Security Admission

The kube-apiserver enforces PSA `restricted` cluster-wide via `templates/admission-config.yaml.tftpl`. Concretely, every pod in a non-exempt namespace must:

- run as a non-root UID (`runAsNonRoot: true`, no UID 0)
- not allow privilege escalation (`allowPrivilegeEscalation: false`)
- drop ALL Linux capabilities (`capabilities.drop: [ALL]`)
- use the runtime default seccomp profile (`seccompProfile.type: RuntimeDefault`)
- not mount `hostPath`, not use `hostNetwork`/`hostPID`/`hostIPC`, not run privileged

Exempt namespaces (where the controllers genuinely need elevated privileges): `kube-system`, `tigera-operator`, `calico-system`, `calico-apiserver`, `rook-ceph`, `falco`, `trivy-system`, `traefik`, `velero`, `vector`, `argocd`, `monitoring`. Edit the `exemptions.namespaces` list in the template if you need to add more, but treat each addition as a security review item.

The `default` namespace also carries explicit `pod-security.kubernetes.io/{enforce,audit,warn}=restricted` labels (set in `96-default-sa-no-automount.tf`). The labels override the cluster default, so even if you later relax the cluster-wide setting, `default` stays locked down.

### What this breaks

Stock images that run as root will fail to admit. Common fixes for your own workloads:

```yaml
spec:
  securityContext:
    runAsNonRoot: true
    runAsUser: 65532          # or any non-zero UID supported by your image
    seccompProfile:
      type: RuntimeDefault
  containers:
    - name: app
      securityContext:
        allowPrivilegeEscalation: false
        capabilities:
          drop: [ALL]
```

For new application namespaces, copy `examples/networkpolicy-template.yaml` — the Namespace block at the top of that file applies the same labels.

### What this *doesn't* catch

PSA only checks pod creates/updates against a fixed rule set. It doesn't validate image registries, image tags, resource quotas, or runtime behavior. Layer Kyverno on top for those (next milestone).

### Existing-cluster rollout

The cluster-default change in `admission-config.yaml.tftpl` only takes effect when an apiserver static pod restarts. On a freshly-applied cluster this happens automatically. On an existing cluster from before this change, push the new file to each CP under `/etc/kubernetes/admission-config.yaml` and `crictl rmp` the apiserver pod (kubelet recreates it). The per-namespace label on `default` doesn't need any of that — it took effect the moment Terraform applied it.

## Kyverno admission policies

PSA covers privilege/root/capabilities at the apiserver level, but it can't filter by registry, tag, or auto-generate companion resources. Kyverno does. It runs as a Deployment in the `kyverno` namespace and intercepts every API write through a validating + mutating webhook.

5 starter `ClusterPolicy` resources are applied from `templates/kyverno-policies.yaml.tftpl` after the Kyverno webhook is ready:

| Policy | Action | Effect |
|---|---|---|
| `disallow-latest-tag` | validate (Enforce) | Reject pods whose images use `:latest` or omit the tag entirely |
| `restrict-image-registries` | validate (Enforce) | Reject pods whose images aren't from an allowlisted registry (see `var.kyverno_allowed_registries`) |
| `generate-default-network-policy` | generate | Auto-create a default-deny NetworkPolicy in every newly-created non-exempt namespace |
| `require-resource-limits` | validate (Enforce) | Reject pods missing `resources.requests.{cpu,memory}` or `resources.limits.memory`. CPU limit deliberately not required |
| `disallow-default-serviceaccount` | validate (Enforce) | Reject pods that use the `default` ServiceAccount — forces explicit SA per workload |

All five exempt the same namespace list as PSA (`var.kyverno_policy_exempt_namespaces`) plus `kube-public`, `kube-node-lease`, and `kyverno` itself. Edit either var to add or remove.

### Try it

```bash
kubectl run test --image=nginx:latest
# → Error: validation error: Image tag :latest is not allowed; pin a specific tag.

kubectl run test --image=nginx:1.27 --dry-run=server -o yaml
# → Error: validation error: Containers must declare resources.requests.{cpu,memory} ...

kubectl create namespace foo
kubectl get netpol -n foo
# → default-deny   <none>   2s   (auto-generated by Kyverno)

kubectl create namespace bar
kubectl run app -n bar --image=docker.io/library/nginx:1.27 \
  --overrides='{"spec":{"serviceAccountName":"bar-sa","containers":[{"name":"app","image":"docker.io/library/nginx:1.27","resources":{"requests":{"cpu":"50m","memory":"64Mi"},"limits":{"memory":"128Mi"}}}]}}'
# → Error: validation error: Pods must use a non-default ServiceAccount.
#   (Kyverno checks before the apiserver creates the missing SA — create the SA first.)
```

### Adjusting

- **Add a private registry**: append to `kyverno_allowed_registries` in `terraform.tfvars` and re-apply. The `restrict-image-registries` policy re-renders.
- **Exempt a namespace**: add it to `kyverno_policy_exempt_namespaces` in `terraform.tfvars`. Re-apply pushes the updated policies cluster-wide.
- **Make a policy advisory instead of blocking**: edit `templates/kyverno-policies.yaml.tftpl` and change `validationFailureAction: Enforce` to `Audit` for that ClusterPolicy. Failures show up as `PolicyReport` resources but don't block pods.
- **Disable a single policy entirely**: `kubectl delete clusterpolicy <name>` (Terraform won't recreate it on its own — re-apply if you want it back).

### Failure modes

Kyverno's webhooks are configured `failurePolicy: Fail`. If the Kyverno admission controller is down, pod creates in non-exempt namespaces fail with `failed to call webhook`. The chart excludes `kube-system` from the webhook namespaceSelector so the cluster can self-recover (the Kyverno Deployment itself can roll). If you ever lock yourself out:

```bash
kubectl delete validatingwebhookconfiguration kyverno-policy-validating-webhook-cfg \
                                              kyverno-resource-validating-webhook-cfg
# unblocks admissions; re-apply terraform to restore them once Kyverno is healthy.
```

## Sealed Secrets

A `sealed-secrets` controller runs in `kube-system` (Bitnami chart). The master key is **persistent across `terraform destroy && terraform apply`**: it's generated once, age-encrypted, committed to this repo at `secrets/sealed-secrets-master.key.yaml.age`, and decrypted + applied to the cluster on every apply *before* the controller starts.

### First-time setup (per cluster lifetime)

Two helper scripts cover the one-time setup:

```bash
# 1. (Per operator machine — only if you don't already have an age identity)
./scripts/gen-age-identity.sh
# Writes ~/.config/sops/age/keys.txt and prints your public key (age1...).

# 2. Encrypt the master-key Secret manifest into a committable blob.
./scripts/gen-sealed-secrets-master-key.sh age1<your-recipient>

# 3. Commit the blob.
git add secrets/sealed-secrets-master.key.yaml.age
git commit -m "sealed-secrets: persistent master key"

# 4. Same recipient also encrypts daily etcd snapshots — set it in tfvars.
echo 'etcd_snapshot_age_recipient = "age1<your-recipient>"' >> terraform.tfvars

# 5. (Only if your age identity lives somewhere other than the default ~/.config/sops/age/keys.txt)
echo 'sealed_secrets_age_identity_path = "/path/to/your/keys.txt"' >> terraform.tfvars
```

**Back up `~/.config/sops/age/keys.txt`** (the age private key) somewhere offline — 1Password, encrypted USB, anywhere. Without it, the encrypted blob is unreadable and a rebuilt cluster cannot restore the master key. Same applies to encrypted etcd snapshots.

### Per-apply

Nothing manual. `terraform apply` decrypts the blob and applies the master key Secret to `kube-system` before the controller starts.

### Day-to-day kubeseal usage

```bash
# 1. Install kubeseal locally (brew install kubeseal, or grab from GitHub releases).

# 2. Author a normal Secret (don't commit this!)
kubectl create secret generic db-creds \
  --from-literal=password=hunter2 \
  --dry-run=client -o yaml > db-creds.yaml

# 3. Encrypt against the cluster's public key → SealedSecret (safe to commit)
kubeseal --format yaml < db-creds.yaml > db-creds.sealed.yaml

# 4. Apply (or let your GitOps tool do it)
kubectl apply -f db-creds.sealed.yaml
```

### Disaster recovery

Same age identity → same master key → every committed SealedSecret stays decryptable across destroy/apply cycles, fresh-machine setups, multi-operator workflows.

If you lose the age identity but still have the encrypted blob: nothing decrypts it, both the blob and every SealedSecret in git become garbage. The age private key is the only thing that matters — back it up like you'd back up an SSH master key.

### Rotation (rare)

Rotation invalidates every existing SealedSecret in git. Only rotate if the master key is compromised:

```bash
rm secrets/sealed-secrets-master.key.yaml.age
./scripts/gen-sealed-secrets-master-key.sh age1<recipient>
git commit -am "sealed-secrets: rotate master key"
terraform apply
# Then re-seal every SealedSecret in the gitops repo against the new public cert.
```

### Recovering from an auto-generated key

If for some reason the controller has already started and generated its own key (e.g. earlier apply ran without the encrypted blob present), `terraform apply` will overwrite the labeled Secret but the running controller pod still uses the old key in memory:

```bash
kubectl -n kube-system rollout restart deployment sealed-secrets-controller
```

After restart, the controller picks up the persistent key. Old SealedSecrets sealed against the auto-generated key are now unreadable — re-seal them from their plaintext sources.

## Argo CD

Argo CD runs in the `argocd` namespace (Argo Helm chart, `var.argocd_chart_version`). The namespace is exempted from PSA `restricted` and from the Kyverno starter policies — the chart's bundled images don't all comply, and tightening it case-by-case is out of scope for the initial install.

### Admin password (persistent across destroy/apply)

The Argo admin password is **persistent across `terraform destroy && terraform apply`**: it's generated once via a helper script, age-encrypted into `secrets/argocd-admin-password.yaml.age` (committed to this repo), and decrypted + applied to the cluster on every apply *before* the chart starts. Same persistence pattern as the sealed-secrets master key.

**First-time setup** (once per cluster lifetime):

```bash
# Generate a persistent admin password (random 24-char) + commit
./scripts/gen-argocd-admin-password.sh age1<your-recipient>
git add secrets/argocd-admin-password.yaml.age
git commit -m "argocd: persistent admin password"

# OR pass your own password
./scripts/gen-argocd-admin-password.sh age1<your-recipient> 'my-strong-password'
```

The script bcrypt-hashes the password (cost 10), generates an `argocd-server` signing key, and builds the `argocd-secret` Secret manifest. The chart is configured with `configs.secret.createSecret: false` so it uses this pre-existing Secret instead of generating its own random password.

**Per-apply**: nothing manual. `terraform apply` decrypts the blob and applies the Secret to `argocd` namespace before the chart runs.

**Rotation**: `rm secrets/argocd-admin-password.yaml.age && ./scripts/gen-argocd-admin-password.sh age1<recipient>` then `terraform apply`. Bumps `passwordMtime` (invalidates existing sessions) and the new password takes effect on next pod restart.

### Access the UI

**Without a hostname** (default — `var.argocd_hostname = ""`): port-forward.

```bash
kubectl -n argocd port-forward svc/argocd-server 8080:80
# → open http://localhost:8080
```

**With a hostname** (set `var.argocd_hostname = "argocd.example.com"` in `terraform.tfvars`): Terraform creates an HTTPRoute on the Traefik gateway. Point the DNS record at the services LB IP from `terraform output services_lb_ipv4`. Argo CD serves plain HTTP from the pod (`server.insecure: true`); TLS is terminated at Traefik when `var.traefik_tls_cert_secret_name` is configured (otherwise UI is HTTP-only).

### App-of-Apps bootstrap (terraform-managed)

When `var.argocd_repo_url` is set, terraform wires Argo CD to a private gitops repo on every apply:

1. **Generate a deploy keypair** (once per cluster):

   ```bash
   ssh-keygen -t ed25519 -f secrets/argocd-deploy -N "" -C "argocd@<cluster>"
   ```

   `secrets/` is gitignored; the key never leaves the project.

2. **Add the public key as a GitHub deploy key** — open the gitops repo → *Settings → Deploy keys → Add deploy key* → paste `secrets/argocd-deploy.pub` → leave **Allow write access unchecked** (Argo CD only clones).

3. **Set the repo URL in `terraform.tfvars`**:

   ```hcl
   argocd_repo_url = "git@github.com:owner/k8s-gitops.git"
   # argocd_root_app_path     = "argocd/apps"   # default
   # argocd_root_app_revision = "main"          # default
   ```

4. **`terraform apply`** — creates `Secret/argocd-repo-bootstrap` (the repo connection) + `Application/bootstrap` (the root App-of-Apps).

The root Application syncs `argocd/apps/` from the repo. Every file in that directory becomes a managed Application.

### Expected repo layout

```
my-gitops-repo/
├── argocd/
│   └── apps/                    # ← argocd_root_app_path
│       ├── my-app.yaml          # an Application CR pointing at apps/my-app/
│       └── monitoring.yaml      # an Application CR pointing at apps/monitoring/
└── apps/
    ├── my-app/
    │   ├── deployment.yaml
    │   └── service.yaml
    └── monitoring/
        └── kustomization.yaml
```

Example child `Application` for `argocd/apps/my-app.yaml`:

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: my-app
  namespace: argocd
spec:
  project: default
  source:
    repoURL: git@github.com:owner/k8s-gitops.git
    targetRevision: main
    path: apps/my-app
  destination:
    server: https://kubernetes.default.svc
    namespace: my-app
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
```

Push it to the repo → root Application picks it up on next sync (default 3min, or click "Refresh" in the UI) → child Application starts syncing its own path.

After this is wired, the only ongoing terraform changes are infrastructure-level — application deploys are pure `git push`.

### Connecting additional repos manually

For a second repo (e.g. a separate repo per team), add another repository Secret by hand:

```bash
kubectl -n argocd create secret generic team-x-repo \
  --from-literal=type=git \
  --from-literal=url=git@github.com:owner/team-x-repo.git \
  --from-file=sshPrivateKey=./team-x-deploy
kubectl -n argocd label secret team-x-repo \
  argocd.argoproj.io/secret-type=repository
```

Or commit a `SealedSecret` of it via the gitops repo so the cluster picks it up declaratively.

### Policy-violation visibility

When a manifest violates a Kyverno policy (or PSA), Argo CD's sync fails with the admission webhook's verbatim error message. Look at the failed resource in the UI ("Sync Status" tile) or:

```bash
argocd app sync my-app
# → resource Pod/my-app/web was blocked due to the following policies
#     disallow-latest-tag:
#       forbid-latest-tag: 'validation error: Image tag :latest is not allowed; pin a specific tag.'
```

Wire up `argocd-notifications` later if you want sync-failure pings going to the same Slack channel as the audit alerts.

## Audit-log shipping (Vector)

The kube-apiserver writes audit events to `/var/log/kubernetes/audit.log` on each control-plane node. Without shipping them off-cluster, an attacker with root on a CP can wipe the trail. Vector tails the file and writes to a Hetzner Object Storage bucket (S3-compatible, append-only by IAM policy if you want).

To enable:

1. **Hetzner Cloud Console** → Object Storage → create a *separate* bucket from the Velero one (e.g. `k8s-audit-logs`).
2. Create dedicated S3 credentials for it (don't reuse Velero's — separation of blast radius).
3. Add to `terraform.tfvars`:
   ```hcl
   audit_log_s3_bucket     = "k8s-audit-logs"
   audit_log_s3_access_key = "HCLOUDOBJ..."
   audit_log_s3_secret_key = "..."
   ```
4. `terraform apply` — Vector deploys as a DaemonSet on each CP, tailing the audit log.

Set bucket lifecycle policy to taste (typical: keep ≥1 year for compliance, transition to colder storage after 30 days).

### Live alerts (optional)

S3 shipping is forensic — you only look after something went wrong. To get *notified* when high-signal events happen, point Vector at a Slack-compatible incoming webhook. The same DaemonSet classifies every audit event and POSTs matches to the webhook:

| Category | Severity | Triggers when |
|---|---|---|
| `anonymous_auth` | high | `system:anonymous` made any request (allow-list paths in `audit-policy.yaml` are filtered out before classification) |
| `rbac_mutation` | high | `create`/`update`/`patch`/`delete` on `clusterrolebindings`, `rolebindings`, `clusterroles`, `roles` |
| `privileged_pod` | high | A human user (not a ServiceAccount or kubelet) created a Pod with `hostNetwork`, `hostPID`, `hostIPC`, a `hostPath` volume, or any container with `securityContext.privileged: true`. Controllers like calico-node legitimately do this and are intentionally excluded. |
| `pod_exec` | medium | Anyone called `pods/exec` or `pods/attach` (the "I'm SSHing into a container" event) |
| `secret_read_by_human` | medium | `get`/`list` on `secrets` by a non-ServiceAccount, non-node, non-apiserver identity |

Each category is rate-limited to **30 events/minute** so a runaway loop can't drown the channel. Each alert message includes the source IP and a `source_zone` tag (`node-network` / `pod-network` / `service-network` / `external`) to speed up triage.

To enable, add to `terraform.tfvars`:

```hcl
audit_log_alert_webhook_url = "https://hooks.slack.com/services/T.../B.../..."
```

Slack: *Apps → Incoming Webhooks → Add → copy URL*. Discord works too — append `/slack` to the Discord webhook URL for Slack-format compatibility.

#### Two-channel routing (optional)

For larger setups, route the high-severity stuff (anonymous auth, RBAC mutations, privileged pods) to a dedicated `#security` channel and keep the medium-severity stuff plus heartbeats on the primary channel:

```hcl
audit_log_alert_webhook_url          = "https://hooks.slack.com/.../ops"
audit_log_alert_security_webhook_url = "https://hooks.slack.com/.../security"
```

#### Heartbeat & dead-man's switch

Each Vector pod posts a `heartbeat` message to the primary webhook **once per hour**. If you stop seeing heartbeats from any CP, something is wrong (Vector crashed, networking blocked, sink down). Add a calendar reminder or alert on absence of `[k8s audit] heartbeat` for >2h.

#### Sink delivery failure visibility

If a webhook starts returning 5xx or rejecting payloads, Vector retries then drops. To make this visible, the pipeline forwards Vector's own ERROR-level internal logs to the primary webhook (rate-limited to 3/5min so a misconfigured sink can't itself spam you). You'll see messages like `[k8s audit/sink-error] ...`.

Note the chicken-and-egg: if the *primary* webhook itself is down, sink-error notices about it can't be delivered. The hourly heartbeat is the backstop — its silence is the signal.

#### Verify after apply

```bash
# pod_exec → primary channel (medium)
kubectl run audit-test --rm -it --image=busybox --restart=Never -- sh -c 'exit'

# rbac_mutation → security channel if dual-routed, else primary (high)
kubectl create clusterrolebinding audit-test --clusterrole=view --user=nobody
kubectl delete clusterrolebinding audit-test
```

Tune categories or add new ones in `helm-values/vector.values.yaml.tftpl` (the `classify_alerts` remap).

## Backups (Velero)

Velero is wired in but only installs when you provide a Hetzner Object Storage bucket. To enable:

1. **Hetzner Cloud Console** → Cloud → Object Storage → create bucket (e.g. `k8s-velero-backups`).
2. Same screen → create S3 credentials; save the access + secret keys.
3. Add to `terraform.tfvars`:
   ```hcl
   velero_s3_bucket     = "k8s-velero-backups"
   velero_s3_access_key = "HCLOUDOBJ..."
   velero_s3_secret_key = "..."
   ```
4. `terraform apply` — Velero gets installed, defaults to a 30-day TTL on backups.

Cost: ~€0.49/month per 100 GB stored; egress free within Hetzner.

After installation, schedule daily cluster-wide backups with the bundled `velero` CLI:

```bash
velero schedule create daily --schedule="0 2 * * *" --include-namespaces='*'
velero backup get   # list backups
velero restore create --from-backup daily-20260425020000   # restore (DR drill)
```

This complements the per-CP etcd snapshot timer (which only protects etcd, not PVs or non-etcd resources).

## Metrics & alerting (kube-prometheus-stack)

Always installed in the `monitoring` namespace: Prometheus + Alertmanager + Grafana + node-exporter + kube-state-metrics + the prometheus-operator. Tuned for a 3+3 cluster — Prometheus requests 1 GiB / 250m CPU and retains 14 days of metrics on a 25 GiB Ceph PVC. Bump `prometheus_retention` / `prometheus_pvc_size` if you scale workers and want longer history.

The chart's ServiceMonitor selectors are configured to scrape **any** ServiceMonitor / PodMonitor / PrometheusRule in the cluster, regardless of release label — so metrics from Trivy, Argo CD, cert-manager, Traefik, etc., light up automatically once those projects emit a `ServiceMonitor` (most already do).

### Access Grafana

```bash
# Get the auto-generated admin password
terraform output -raw grafana_admin_password

# Option A: HTTPRoute (set var.prometheus_grafana_hostname + a TLS issuer in tfvars)
#   → open https://grafana.k8s.example.com  (admin / <password from above>)

# Option B: port-forward (no hostname configured)
kubectl -n monitoring port-forward svc/kube-prometheus-stack-grafana 3000:80
# → open http://localhost:3000
```

Default dashboards (Kubernetes/Node/Workload overview, etcd, apiserver, scheduler, kubelet, …) ship with the chart. Custom dashboards can be added via gitops by creating a ConfigMap with label `grafana_dashboard: "1"` in any namespace — the Grafana sidecar discovers and loads them automatically.

### Alerting

Alertmanager ships with ~70 default rules from kube-prometheus. They're noisy out of the box — expect to silence or tune for the first week.

Wire to Slack by adding to `terraform.tfvars`:
```hcl
alertmanager_slack_webhook_url = "https://hooks.slack.com/services/T.../B.../..."
alertmanager_slack_channel     = "#k8s-alerts"
```

The `Watchdog` heartbeat alert is muted by default (it fires constantly by design — wire it to https://deadmanssnitch.com if you want a true dead-man's switch). The `InfoInhibitor` synthetic alert is also muted.

This is **independent** of the audit-log alerts shipped by Vector — those come from the apiserver audit log (anonymous auth, RBAC mutations, secret reads). Prometheus alerts come from cluster metrics (node down, Ceph degraded, cert expiry). They can share or split Slack channels via the two `*_webhook_url` vars.

## etcd encryption key rotation

Rotation is a manual operational procedure (Terraform produces the new config
but doesn't restart kube-apiserver static pods on existing CPs).

```bash
# 1. Capture the CURRENT active key from tfstate (this becomes the retired/decrypt key)
CURRENT_KEY=$(terraform state show random_id.encryption_key | awk '/b64_std/ {print $3}' | tr -d '"')

# 2. Add it to terraform.tfvars as a retired key (so apiserver can still decrypt)
cat >> terraform.tfvars <<EOF
etcd_retired_encryption_keys = [
  { name = "key-old", secret = "${CURRENT_KEY}" },
]
EOF

# 3. Force a new active key + apply (re-renders encryption-config.yaml on NEW CPs only)
terraform taint random_id.encryption_key
terraform apply

# 4. On EACH existing CP node, manually copy the new config and restart kube-apiserver.
#    Node names in kubectl match the SSH aliases generated in ~/.ssh/config.d/.
for cp in $(kubectl get nodes -l node-role.kubernetes.io/control-plane -o name | sed 's|node/||'); do
  scp ./secrets/encryption-config-new.yaml $cp:/etc/kubernetes/encryption-config.yaml
  ssh $cp 'crictl ps --name kube-apiserver -q | xargs -r crictl rm -f'
  sleep 30
done

# 5. Re-encrypt all existing Secrets (with the new active key)
kubectl get secrets -A -o json \
  | jq '.items[] | del(.metadata.resourceVersion,.metadata.uid,.metadata.creationTimestamp,.metadata.managedFields)' \
  | kubectl replace -f -

# 6. Once all Secrets are re-encrypted, REMOVE the retired key from terraform.tfvars,
#    apply again, restart kube-apiserver pods one more time.
```

The simpler alternative: replace the cluster (`./destroy.sh && terraform apply`) — fine for non-prod.

## Teardown

`terraform destroy` hangs on Rook-Ceph helm release cleanup (CephCluster
finalizers vs. operator dying simultaneously). Use the wrapper:

```bash
./destroy.sh
```

It strips `helm_release.*` from state first, then runs `terraform destroy`. The
in-cluster resources die naturally with the nodes.

## Notes

- **Bootstrap token TTL is 24h.** To add or replace a node after that window, rotate the token: `terraform taint random_string.bt_secret && terraform apply`.
- **Node private IPs** are auto-assigned by Hetzner — stable per server-id, never renumbered on scale up. Each kubelet detects its own IP at runtime in `bootstrap-common.sh`.
- **Apt upgrade + reboot** runs once on each fresh node so kernel patches apply cleanly. A systemd one-shot resumes the bootstrap script after the reboot. Adds ~30-60s to first-boot.
- **Anonymous auth** is restricted to a tiny allow-list (`/healthz`, `/livez`, `/readyz`, `cluster-info`) via `AuthenticationConfiguration` instead of fully off — required so `kubeadm join` discovery works.
- **IPv6 pod CIDR `2001:db8:95::/56`** uses the IETF documentation prefix on purpose — Calico NATs IPv6 pod traffic to each node's public IPv6.
- **First-apply provider warning** like `'config_path' refers to an invalid path: "./secrets/admin.conf": stat: no such file or directory` is expected — the kubernetes/helm providers defer connection until the kubeconfig is fetched mid-apply via the `depends_on` chain. Non-fatal.
- **Gateway API listener port gotcha**: a Gateway listener's `port` must match Traefik's *internal* entryPoint port (HTTP `8000`, HTTPS `8443`), NOT the external `80`/`443`. The Service NodePort handles the 80→8000 / 443→8443 mapping. HTTPRoute `backendRefs[].port` is the *Service's* own port (typically 80).
- **Traefik experimental Gateway API channel is OFF**: Traefik's gateway controller stalls if `experimentalChannel: true` is set without the matching CRDs (TCPRoute/TLSRoute/etc.) installed. We use the standard channel only — HTTPRoute, GRPCRoute, ReferenceGrant work; install [experimental CRDs](https://gateway-api.sigs.k8s.io/guides/) yourself if you need TCPRoute/TLSRoute and flip the value back on.
