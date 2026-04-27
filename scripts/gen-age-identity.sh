#!/usr/bin/env bash
#
# Generate a new age identity at ~/.config/sops/age/keys.txt. Run ONCE per
# operator machine. The printed public key (recipient) is what you paste into
# terraform.tfvars (etcd_snapshot_age_recipient) and pass to
# scripts/gen-sealed-secrets-master-key.sh.
#
# Usage: ./scripts/gen-age-identity.sh

set -euo pipefail

DEFAULT_PATH="$HOME/.config/sops/age/keys.txt"

if ! command -v age-keygen >/dev/null; then
  echo "ERROR: 'age-keygen' not found in PATH. Install age first (e.g. brew install age)." >&2
  exit 1
fi

if [ -e "$DEFAULT_PATH" ]; then
  echo "ERROR: $DEFAULT_PATH already exists." >&2
  echo "       Generating a fresh identity here would overwrite the existing one and" >&2
  echo "       lock you out of every blob already encrypted with the old recipient." >&2
  echo "       To inspect the current public key: age-keygen -y '$DEFAULT_PATH'" >&2
  exit 1
fi

mkdir -p "$(dirname "$DEFAULT_PATH")"
age-keygen -o "$DEFAULT_PATH"

echo
echo "Identity written to: $DEFAULT_PATH (mode 600)"
echo
echo "BACK THIS FILE UP OFFLINE NOW (1Password / encrypted USB / etc.)."
echo "Without it, every age-encrypted blob in the repo and every encrypted etcd"
echo "snapshot becomes unreadable forever."
echo
echo "Next: copy the 'Public key:' line above into terraform.tfvars as"
echo "  etcd_snapshot_age_recipient = \"age1...\""
echo "and pass it to ./scripts/gen-sealed-secrets-master-key.sh as the recipient."
