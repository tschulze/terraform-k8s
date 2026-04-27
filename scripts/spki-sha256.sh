#!/usr/bin/env bash
#
# Compute the SHA256 of a CA certificate's SubjectPublicKeyInfo (SPKI).
# Used by kubeadm `caCertHashes` to pin the cluster CA at join time so
# `unsafeSkipCAVerification: true` can be dropped from JoinConfiguration.
#
# Called from a `data "external"` block — reads JSON {"cert_pem": "..."}
# on stdin, writes JSON {"hash": "..."} (just the hex, no algorithm prefix —
# kubeadm wants `sha256:<hex>` so the caller adds the prefix).

set -euo pipefail

for cmd in jq openssl awk; do
  command -v "$cmd" >/dev/null || { echo "ERROR: '$cmd' not found in PATH" >&2; exit 1; }
done

cert_pem="$(jq -r '.cert_pem')"
[ -n "$cert_pem" ] || { echo "ERROR: empty cert_pem on stdin" >&2; exit 1; }

hash="$(printf '%s' "$cert_pem" | \
  openssl x509 -pubkey -noout 2>/dev/null | \
  openssl pkey -pubin -outform der 2>/dev/null | \
  openssl dgst -sha256 2>/dev/null | awk '{print $NF}')"
[ -n "$hash" ] || { echo "ERROR: failed to compute SPKI sha256 — is cert_pem a valid X.509 PEM?" >&2; exit 1; }

jq -n --arg h "$hash" '{hash: $h}'
