#!/usr/bin/env bash
#
# Generate a persistent Argo CD admin password Secret, age-encrypt it, and
# write it to secrets/argocd-admin-password.yaml.age for committing to this
# repo. Mirrors the sealed-secrets-master-key persistence pattern.
#
# Without this, the Argo chart auto-generates a random admin password on
# every fresh `terraform apply` — your saved login breaks after every
# `destroy && apply`. With this, the same password survives forever (until
# you intentionally rotate by deleting the .age blob and re-running).
#
# Usage:
#   ./scripts/gen-argocd-admin-password.sh <age-recipient>            # generates random password
#   ./scripts/gen-argocd-admin-password.sh <age-recipient> <password> # uses your password

set -euo pipefail

if [ $# -lt 1 ] || [ $# -gt 2 ]; then
  echo "Usage: $0 <age-recipient> [password]" >&2
  echo "       Generate one with: age-keygen -o ~/.config/sops/age/keys.txt" >&2
  exit 1
fi

RECIPIENT="$1"
PASSWORD="${2:-}"
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$REPO_ROOT/secrets/argocd-admin-password.yaml.age"

if [ -e "$OUT" ]; then
  echo "ERROR: $OUT already exists." >&2
  echo "       Rotating the Argo admin password is fine (no SealedSecret-style data loss)," >&2
  echo "       but for safety you have to delete the blob first:" >&2
  echo "         rm '$OUT' && rerun this script" >&2
  exit 1
fi

for cmd in age openssl htpasswd; do
  if ! command -v "$cmd" >/dev/null; then
    echo "ERROR: '$cmd' not found in PATH." >&2
    exit 1
  fi
done

mkdir -p "$REPO_ROOT/secrets"

if [ -z "$PASSWORD" ]; then
  # Pull alphanumerics straight from /dev/urandom and take exactly 24 chars.
  # Earlier this was `openssl rand -base64 18 | tr -d '/+=' | head -c 24`, which
  # ALWAYS truncated to ≤24 — but stripping `/+=` from a base64 output of length
  # 24 routinely yielded shorter strings (and silently shipped them as the admin
  # password). Oversampling /dev/urandom guarantees the requested length and
  # 24 alphanumeric chars = ~143 bits of entropy.
  PASSWORD="$(LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom | head -c 24)"
  echo "Generated random password (24 chars): $PASSWORD"
  echo "  Save this in your password manager — only you and the SealedSecret know it."
  echo
fi

# Bcrypt the password (cost 10 — Argo's default). htpasswd outputs `:hash`;
# strip the leading colon. Pipe via stdin (-i) instead of -b so the password
# never appears in argv (which would be visible to anyone running `ps` during
# the htpasswd run, however briefly).
BCRYPT_HASH="$(printf '%s\n' "$PASSWORD" | htpasswd -niBC 10 "" | tr -d ':\n')"

# Server signing key — used by argocd-server to sign auth tokens. 64 random
# hex chars matches the chart's auto-generated default.
SERVER_SECRETKEY="$(openssl rand -hex 32)"

# ISO-8601 timestamp; Argo uses this to invalidate sessions if the password
# changes. Static value here means no spurious session invalidation between
# applies — but rotating the password (delete + regen) WILL bump it.
NOW="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT

cat > "$TMPDIR/secret.yaml" <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: argocd-secret
  namespace: argocd
  labels:
    app.kubernetes.io/name: argocd-secret
    app.kubernetes.io/part-of: argocd
type: Opaque
stringData:
  admin.password: '$BCRYPT_HASH'
  admin.passwordMtime: '$NOW'
  server.secretkey: '$SERVER_SECRETKEY'
EOF

age -r "$RECIPIENT" -o "$OUT" "$TMPDIR/secret.yaml"

echo "Created: $OUT"
echo
echo "Next steps:"
echo "  1. git add '$OUT' && git commit -m 'argocd: persistent admin password'"
echo "  2. terraform apply  (or destroy+apply for a clean test)"
echo
echo "Login: admin / <the password above>"
echo "Rotation: rm '$OUT' && rerun this script (no data loss; just bumps mtime)"
