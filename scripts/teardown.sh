#!/usr/bin/env bash
#
# Tears down the Kind cluster created by setup-cluster.sh
#
set -euo pipefail

CLUSTER_NAME="${CLUSTER_NAME:-reproducible-demo}"

if docker info >/dev/null 2>&1; then
  export KIND_EXPERIMENTAL_PROVIDER=""
elif podman info >/dev/null 2>&1; then
  export KIND_EXPERIMENTAL_PROVIDER=podman
fi

echo "Deleting Kind cluster '${CLUSTER_NAME}'..."
kind delete cluster --name "${CLUSTER_NAME}"
echo "Done."
