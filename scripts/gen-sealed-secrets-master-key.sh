#!/usr/bin/env bash
#
# Generate a fresh RSA-4096 keypair for the sealed-secrets controller and
# encrypt it with age for committing to this repo. Run ONCE per cluster
# lifetime. Rotation is the same command but requires deleting the existing
# blob first AND re-sealing every committed SealedSecret afterward.
#
# Usage: ./scripts/gen-sealed-secrets-master-key.sh <age-recipient>
# Example: ./scripts/gen-sealed-secrets-master-key.sh age1abc...xyz

set -euo pipefail

if [ $# -ne 1 ]; then
  echo "Usage: $0 <age-recipient>" >&2
  echo "       Generate one with: age-keygen -o ~/.config/sops/age/keys.txt" >&2
  exit 1
fi

RECIPIENT="$1"
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$REPO_ROOT/secrets/sealed-secrets-master.key.yaml.age"

if [ -e "$OUT" ]; then
  echo "ERROR: $OUT already exists." >&2
  echo "       Rotating the master key invalidates every existing SealedSecret in git." >&2
  echo "       To rotate intentionally: rm '$OUT' && rerun this script, then re-seal everything." >&2
  exit 1
fi

if ! command -v age >/dev/null; then echo "ERROR: 'age' not found in PATH." >&2; exit 1; fi
if ! command -v openssl >/dev/null; then echo "ERROR: 'openssl' not found in PATH." >&2; exit 1; fi

mkdir -p "$REPO_ROOT/secrets"

TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT

openssl req -x509 -nodes -newkey rsa:4096 \
  -keyout "$TMPDIR/tls.key" -out "$TMPDIR/tls.crt" \
  -subj "/CN=sealed-secret/O=sealed-secret" \
  -days 36500 >/dev/null 2>&1

# Portable base64 (no -w 0 / -i): GNU and BSD agree on stdin-mode, both wrap
# at 76 chars by default; tr strips the wraps.
TLS_CRT_B64="$(base64 < "$TMPDIR/tls.crt" | tr -d '\n')"
TLS_KEY_B64="$(base64 < "$TMPDIR/tls.key" | tr -d '\n')"

cat > "$TMPDIR/secret.yaml" <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: sealed-secrets-key-bootstrap
  namespace: kube-system
  labels:
    sealedsecrets.bitnami.com/sealed-secrets-key: active
type: kubernetes.io/tls
data:
  tls.crt: $TLS_CRT_B64
  tls.key: $TLS_KEY_B64
EOF

age -r "$RECIPIENT" -o "$OUT" "$TMPDIR/secret.yaml"

echo "Created: $OUT"
echo
echo "Next steps:"
echo "  1. git add '$OUT' && git commit -m 'sealed-secrets: persistent master key'"
echo "  2. Set var.sealed_secrets_age_identity_path in terraform.tfvars (default: ~/.config/sops/age/keys.txt)"
echo "  3. terraform apply"
echo
echo "Back up your age private key (the one matching $RECIPIENT) offline — without it,"
echo "the encrypted blob is unreadable and a fresh cluster build cannot restore the master key."
