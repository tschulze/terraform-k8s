#!/usr/bin/env bash
#
# Discover latest stable versions for every Helm chart referenced by a
# `helm_release` resource in the terraform-k8s repo and report (or apply)
# updates to the matching chart_version variable defaults in variables.tf.
#
# Usage:
#   ./scripts/check-helm-versions.sh                   # dry-run, just report
#   ./scripts/check-helm-versions.sh --apply           # rewrite variables.tf in place
#   ./scripts/check-helm-versions.sh --include-prerelease   # don't skip rc/beta/alpha
#
# Requires: yq (mikefarah), curl, awk, sed. No Helm CLI needed.
#
# Output columns: chart | repo | current → latest

set -euo pipefail

APPLY=false
INCLUDE_PRE=false
for arg in "$@"; do
  case "$arg" in
    --apply)              APPLY=true ;;
    --include-prerelease) INCLUDE_PRE=true ;;
    -h|--help)
      head -15 "$0" | sed 's/^# \?//'
      exit 0 ;;
    *) echo "Unknown arg: $arg (use --help)" >&2; exit 1 ;;
  esac
done

for cmd in yq curl awk sed; do
  command -v "$cmd" >/dev/null || { echo "ERROR: '$cmd' not found in PATH." >&2; exit 1; }
done

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VARS_FILE="$REPO_ROOT/variables.tf"

# Cache repo index downloads (one HTTP request per unique repoURL per run).
INDEX_CACHE_DIR="$(mktemp -d)"
trap 'rm -rf "$INDEX_CACHE_DIR"' EXIT

fetch_index() {
  local repo_url="$1"
  local cache_key index_file
  cache_key="$(printf '%s' "$repo_url" | shasum -a 256 | cut -d' ' -f1)"
  index_file="$INDEX_CACHE_DIR/$cache_key.yaml"
  if [ ! -f "$index_file" ]; then
    if ! curl -sfL "$repo_url/index.yaml" -o "$index_file" 2>/dev/null; then
      return 1
    fi
  fi
  printf '%s' "$index_file"
}

get_latest_version() {
  local index_file="$1" chart_name="$2"
  if "$INCLUDE_PRE"; then
    yq -r ".entries[\"$chart_name\"][0].version // \"\"" "$index_file" 2>/dev/null
  else
    yq -r "
      .entries[\"$chart_name\"][]
      | select(.version | test(\"-(alpha|beta|rc|pre|dev|snapshot|ea)\") | not)
      | .version
    " "$index_file" 2>/dev/null | head -1
  fi
}

# Returns the variable default value for a given variable name from variables.tf.
get_var_default() {
  local var_name="$1"
  awk -v name="$var_name" '
    $1 == "variable" && $2 == "\"" name "\"" { in_block = 1; next }
    in_block && /^}/ { in_block = 0 }
    in_block && /^[[:space:]]*default[[:space:]]*=/ {
      sub(/^[[:space:]]*default[[:space:]]*=[[:space:]]*"/, "")
      sub(/"[[:space:]]*$/, "")
      print
      exit
    }
  ' "$VARS_FILE"
}

UPDATED=0
ERRORED=0

printf '%-30s  %-10s  %-12s  %s\n' "VAR" "CURRENT" "LATEST" "REPO"
printf '%-30s  %-10s  %-12s  %s\n' "---" "-------" "------" "----"

# Walk every helm_release in the repo. We extract:
#   - chart name from the `chart = "..."` line
#   - repo from the `repository = "..."` line (in same resource block)
#   - the var name from `version = var.X_chart_version`
for tf_file in "$REPO_ROOT"/helm-*.tf; do
  [ -e "$tf_file" ] || continue
  # Use awk to find each helm_release block's chart, repo, and version-var.
  while IFS=$'\t' read -r chart repo var_name; do
    [ -z "$chart" ] && continue
    current="$(get_var_default "$var_name")"
    if [ -z "$current" ]; then
      printf '%-30s  %-10s  %-12s  %s  [no default in variables.tf]\n' "$var_name" "?" "?" "$repo"
      ERRORED=$((ERRORED + 1))
      continue
    fi

    if ! index_file="$(fetch_index "$repo")"; then
      printf '%-30s  %-10s  %-12s  %s  [index.yaml fetch failed]\n' "$var_name" "$current" "?" "$repo"
      ERRORED=$((ERRORED + 1))
      continue
    fi

    latest="$(get_latest_version "$index_file" "$chart" || true)"
    if [ -z "$latest" ] || [ "$latest" = "null" ]; then
      printf '%-30s  %-10s  %-12s  %s  [chart not in index]\n' "$var_name" "$current" "?" "$repo"
      ERRORED=$((ERRORED + 1))
      continue
    fi

    cur_norm="${current#v}"
    latest_norm="${latest#v}"

    if [ "$cur_norm" = "$latest_norm" ]; then
      printf '%-30s  %-10s  %-12s  %s\n' "$var_name" "$current" "(latest)" "$repo"
    else
      printf '%-30s  %-10s  %-12s  %s\n' "$var_name" "$current" "→ $latest" "$repo"
      UPDATED=$((UPDATED + 1))
      if "$APPLY"; then
        # Replace the default value for this variable. Use awk for safety —
        # sed risks matching the same default elsewhere.
        awk -v name="$var_name" -v new="$latest" '
          BEGIN { in_block = 0 }
          $1 == "variable" && $2 == "\"" name "\"" { in_block = 1 }
          in_block && /^}/ { in_block = 0 }
          in_block && /^[[:space:]]*default[[:space:]]*=/ {
            sub(/=[[:space:]]*"[^"]*"/, "= \"" new "\"")
          }
          { print }
        ' "$VARS_FILE" > "$VARS_FILE.new" && mv "$VARS_FILE.new" "$VARS_FILE"
      fi
    fi
  done < <(awk '
    /^resource[[:space:]]+"helm_release"/ { in_block = 1; chart=""; repo=""; ver="" }
    in_block && /^[[:space:]]*chart[[:space:]]*=[[:space:]]*"/ {
      match($0, /"[^"]+"/); chart = substr($0, RSTART+1, RLENGTH-2)
    }
    in_block && /^[[:space:]]*repository[[:space:]]*=[[:space:]]*"/ {
      match($0, /"[^"]+"/); repo = substr($0, RSTART+1, RLENGTH-2)
    }
    # Match `version = var.X` AND `version = trimprefix(var.X, "v")` etc.
    in_block && /^[[:space:]]*version[[:space:]]*=/ && /var\./ {
      match($0, /var\.[a-z_]+/); ver = substr($0, RSTART+4, RLENGTH-4)
    }
    in_block && /^}/ {
      if (chart && repo && ver) printf "%s\t%s\t%s\n", chart, repo, ver
      in_block = 0
    }
  ' "$tf_file")
done

echo
echo "Summary:"
echo "  ${UPDATED} chart(s) outdated"
echo "  ${ERRORED} error(s)"
if "$APPLY"; then
  echo
  echo "variables.tf rewritten. Review with: cd $REPO_ROOT && git diff variables.tf"
elif [ "$UPDATED" -gt 0 ]; then
  echo
  echo "Run with --apply to rewrite variables.tf in place."
fi
