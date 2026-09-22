#!/usr/bin/env bash
set -euo pipefail

project_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
# shellcheck source=scripts/lib/frankel-pdm-provenance.sh
source "$project_root/scripts/lib/frankel-pdm-provenance.sh"

frankel_pdm_provenance_validate_lock "$project_root"
temporary=$(mktemp)
trap 'rm -f -- "$temporary"' EXIT
cp "$project_root/$frankel_pdm_provenance_lock_relative_path" "$temporary"
sed -i '1p' "$temporary"
if frankel_pdm_provenance_validate_lock_at \
    "$project_root" "$temporary" >/dev/null 2>&1; then
  printf 'error: duplicate provenance entry passed validation\n' >&2
  exit 1
fi

printf 'Frankel PDM provenance simulation: PASS\n'
