#!/usr/bin/env bash
#
# Records the hermetic execution demo for playback during the talk.
# Hermetic mode requires Docker (not Podman), so this script creates
# a temporary Docker-backed Kind cluster, runs the demo, and captures
# the output.
#
# Usage: ./scripts/record-hermetic-demo.sh
# Output: talk/recordings/hermetic-demo.txt
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "${SCRIPT_DIR}")"
CLUSTER_NAME="hermetic-demo-recording"
OUTPUT_DIR="${PROJECT_DIR}/talk/recordings"
OUTPUT_FILE="${OUTPUT_DIR}/hermetic-demo.txt"

BOLD='\033[1m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
RESET='\033[0m'

info()  { echo -e "${BOLD}$*${RESET}"; }
pass()  { echo -e "${GREEN}${BOLD}✓ $*${RESET}"; }

if ! docker info >/dev/null 2>&1; then
  echo "ERROR: Docker is required for hermetic execution recording."
  echo "Start Docker Desktop and try again."
  exit 1
fi

mkdir -p "${OUTPUT_DIR}"

{
  echo "=== Hermetic Execution Demo ==="
  echo "Recorded: $(date '+%Y-%m-%d %H:%M:%S')"
  echo ""

  info "Creating Docker-backed Kind cluster..."
  KIND_EXPERIMENTAL_PROVIDER="" kind create cluster --name "${CLUSTER_NAME}" --wait 120s 2>&1
  pass "Cluster created"
  echo ""

  info "Installing Tekton Pipelines..."
  kubectl --context "kind-${CLUSTER_NAME}" apply --filename \
    "https://storage.googleapis.com/tekton-releases/pipeline/latest/release.yaml" 2>&1 | tail -1
  kubectl --context "kind-${CLUSTER_NAME}" wait --for=condition=available --timeout=120s \
    deployment/tekton-pipelines-controller -n tekton-pipelines 2>&1
  kubectl --context "kind-${CLUSTER_NAME}" wait --for=condition=available --timeout=120s \
    deployment/tekton-pipelines-webhook -n tekton-pipelines 2>&1
  pass "Tekton Pipelines installed"
  echo ""

  info "Enabling alpha API fields for hermetic execution..."
  sleep 5
  kubectl --context "kind-${CLUSTER_NAME}" patch configmap feature-flags -n tekton-pipelines \
    -p '{"data":{"enable-api-fields":"alpha"}}' 2>&1
  pass "Alpha API fields enabled"
  echo ""

  info "Applying hermetic verification task..."
  kubectl --context "kind-${CLUSTER_NAME}" apply -f "${PROJECT_DIR}/tekton/tasks/verify-hermetic.yaml" 2>&1
  pass "Task applied"
  echo ""

  info "Running hermetic TaskRun..."
  echo ""
  echo "  The TaskRun YAML:"
  echo "  ─────────────────"
  cat "${PROJECT_DIR}/tekton/runs/run-hermetic.yaml"
  echo ""
  echo "  ─────────────────"
  echo ""

  HERMETIC_NAME=$(kubectl --context "kind-${CLUSTER_NAME}" create \
    -f "${PROJECT_DIR}/tekton/runs/run-hermetic.yaml" -o jsonpath='{.metadata.name}')
  info "TaskRun: ${HERMETIC_NAME}"
  echo ""

  kubectl --context "kind-${CLUSTER_NAME}" wait --for=condition=Succeeded \
    --timeout=120s "taskrun/${HERMETIC_NAME}" 2>&1
  pass "TaskRun succeeded"
  echo ""

  info "TaskRun logs:"
  echo "─────────────"
  kubectl --context "kind-${CLUSTER_NAME}" logs "${HERMETIC_NAME}-pod" \
    --container=step-verify-no-network 2>&1
  echo "─────────────"
  echo ""

  pass "Hermetic execution demo complete"
  echo ""
  echo "The task tried to reach the internet and was blocked."
  echo "This is Tekton's hermetic execution mode in action."
  echo ""
  echo "In production, you'd structure your pipeline so the BUILD"
  echo "step itself runs hermetically — fetch dependencies first,"
  echo "then build without network access."

} 2>&1 | tee "${OUTPUT_FILE}"

echo ""
info "Cleaning up..."
KIND_EXPERIMENTAL_PROVIDER="" kind delete cluster --name "${CLUSTER_NAME}" 2>&1
pass "Cluster deleted"

echo ""
info "Recording saved to: ${OUTPUT_FILE}"
echo "Show this file during the talk with: cat ${OUTPUT_FILE}"
