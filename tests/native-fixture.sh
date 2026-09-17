#!/usr/bin/env bash
set -Eeuo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"
. "${ROOT_DIR}/tests/cases_generation.sh"
. "${ROOT_DIR}/tests/cases_nodes.sh"
load_functions
stub_side_effects
workdir="${1:?private fixture directory required}"
nodes_fixture "${workdir}"
build_node_objects > "${workdir}/nodes.json"
for number in 1 2 3 4 5; do
  jq -c --argjson number "${number}" '.[] | select(.number==$number)' "${workdir}/nodes.json" \
    | node_object_client_json > "${workdir}/client-${number}.json"
done
