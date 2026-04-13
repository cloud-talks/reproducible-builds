#!/usr/bin/env bash
#
# Tears down the Kind cluster created by setup-cluster.sh
#
set -euo pipefail

CLUSTER_NAME="${CLUSTER_NAME:-reproducible-demo}"

echo "Deleting Kind cluster '${CLUSTER_NAME}'..."
kind delete cluster --name "${CLUSTER_NAME}"
echo "Done."
