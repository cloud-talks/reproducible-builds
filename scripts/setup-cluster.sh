#!/usr/bin/env bash
#
# Sets up a Kind cluster with Tekton Pipelines, Tekton Chains, and cosign
# for the reproducible builds demo.
#
# Prerequisites: kind, kubectl, cosign
#
set -euo pipefail

CLUSTER_NAME="${CLUSTER_NAME:-reproducible-demo}"
TEKTON_PIPELINE_VERSION="${TEKTON_PIPELINE_VERSION:-latest}"
TEKTON_CHAINS_VERSION="${TEKTON_CHAINS_VERSION:-latest}"

info()  { echo "==> $*"; }
ok()    { echo " ✓  $*"; }
fail()  { echo " ✗  $*" >&2; exit 1; }

# ── --check mode: validate cluster without reinstalling ────────────
if [ "${1:-}" = "--check" ]; then
  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  exec "${SCRIPT_DIR}/pre-flight.sh"
fi

# ── Detect container runtime ───────────────────────────────────────
if docker info >/dev/null 2>&1; then
  export KIND_EXPERIMENTAL_PROVIDER=""
  ok "Using Docker as container runtime"
elif podman info >/dev/null 2>&1; then
  export KIND_EXPERIMENTAL_PROVIDER=podman
  ok "Using Podman as container runtime"
else
  fail "Neither Docker nor Podman is running"
fi

# ── Pre-flight checks ──────────────────────────────────────────────
for cmd in kind kubectl cosign; do
  command -v "$cmd" >/dev/null 2>&1 || fail "Required tool not found: $cmd"
done
ok "All required tools found"

# ── 1. Create Kind cluster ─────────────────────────────────────────
if kind get clusters 2>/dev/null | grep -q "^${CLUSTER_NAME}$"; then
  info "Kind cluster '${CLUSTER_NAME}' already exists, reusing it"
else
  info "Creating Kind cluster '${CLUSTER_NAME}'..."
  kind create cluster --name "${CLUSTER_NAME}" --wait 120s
fi
kubectl cluster-info --context "kind-${CLUSTER_NAME}" >/dev/null 2>&1
ok "Kind cluster '${CLUSTER_NAME}' is ready"

# ── 2. Install Tekton Pipelines ────────────────────────────────────
info "Installing Tekton Pipelines (${TEKTON_PIPELINE_VERSION})..."
kubectl apply --filename \
  "https://storage.googleapis.com/tekton-releases/pipeline/${TEKTON_PIPELINE_VERSION}/release.yaml"

info "Waiting for Tekton Pipelines to become ready..."
kubectl wait --for=condition=available --timeout=120s \
  deployment/tekton-pipelines-controller -n tekton-pipelines
kubectl wait --for=condition=available --timeout=120s \
  deployment/tekton-pipelines-webhook -n tekton-pipelines
ok "Tekton Pipelines installed"

# ── 3. Enable alpha features (required for hermetic execution) ─────
info "Enabling alpha API fields for hermetic execution..."
kubectl patch configmap feature-flags -n tekton-pipelines \
  -p '{"data":{"enable-api-fields":"alpha"}}'
ok "Alpha API fields enabled"

# ── 4. Install Tekton Chains ──────────────────────────────────────
info "Installing Tekton Chains (${TEKTON_CHAINS_VERSION})..."
kubectl apply --filename \
  "https://storage.googleapis.com/tekton-releases/chains/${TEKTON_CHAINS_VERSION}/release.yaml"

info "Waiting for Tekton Chains to become ready..."
kubectl wait --for=condition=available --timeout=120s \
  deployment/tekton-chains-controller -n tekton-chains
ok "Tekton Chains installed"

# ── 5. Configure Chains for SLSA provenance ────────────────────────
info "Configuring Tekton Chains..."
kubectl patch configmap chains-config -n tekton-chains -p='{"data":{
  "artifacts.taskrun.format":  "slsa/v2alpha4",
  "artifacts.taskrun.storage": "tekton",
  "artifacts.pipelinerun.format":  "slsa/v2alpha4",
  "artifacts.pipelinerun.storage": "tekton",
  "artifacts.oci.storage": ""
}}'

# Restart the chains controller to pick up config changes
kubectl delete pod -n tekton-chains -l app=tekton-chains-controller --wait=true
info "Waiting for Chains controller to restart..."
kubectl wait --for=condition=available --timeout=120s \
  deployment/tekton-chains-controller -n tekton-chains
ok "Tekton Chains configured"

# ── 6. Generate cosign keypair ─────────────────────────────────────
info "Generating cosign signing keypair..."
if kubectl get secret signing-secrets -n tekton-chains >/dev/null 2>&1; then
  info "Signing secret already exists, skipping keypair generation"
else
  COSIGN_PASSWORD="" cosign generate-key-pair k8s://tekton-chains/signing-secrets
fi
ok "Cosign keypair ready"

# ── 7. Apply Tekton resources ─────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "${SCRIPT_DIR}")"

info "Applying Tasks..."
kubectl apply -f "${PROJECT_DIR}/tekton/tasks/"
ok "Tasks applied"

info "Applying Pipeline..."
kubectl apply -f "${PROJECT_DIR}/tekton/pipelines/"
ok "Pipeline applied"

# ── Done ───────────────────────────────────────────────────────────
echo ""
echo "============================================"
echo "  Cluster is ready for the demo!"
echo "============================================"
echo ""
echo "  Cluster:    kind-${CLUSTER_NAME}"
echo "  Pipelines:  $(kubectl get deploy tekton-pipelines-controller -n tekton-pipelines -o jsonpath='{.metadata.labels.app\.kubernetes\.io/version}')"
echo "  Chains:     $(kubectl get deploy tekton-chains-controller -n tekton-chains -o jsonpath='{.metadata.labels.app\.kubernetes\.io/version}')"
echo ""
echo "  Next step:  ./scripts/run-demo.sh"
echo ""
