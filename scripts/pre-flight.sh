#!/usr/bin/env bash
#
# Pre-flight check for the reproducible builds demo.
# Run this 5 minutes before going on stage.
#
set -euo pipefail

CLUSTER_NAME="${CLUSTER_NAME:-reproducible-demo}"

BOLD='\033[1m'
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[0;33m'
RESET='\033[0m'

PASS=0
FAIL=0
WARN=0

check_pass() { echo -e "  ${GREEN}✓${RESET} $*"; PASS=$((PASS + 1)); }
check_fail() { echo -e "  ${RED}✗${RESET} $*"; FAIL=$((FAIL + 1)); }
check_warn() { echo -e "  ${YELLOW}⚠${RESET} $*"; WARN=$((WARN + 1)); }

echo ""
echo -e "${BOLD}Pre-flight Check: Reproducible Builds Demo${RESET}"
echo -e "${BOLD}$(date '+%Y-%m-%d %H:%M:%S')${RESET}"
echo ""

# ── 1. Kind cluster ───────────────────────────────────────────────
echo -e "${BOLD}Cluster${RESET}"
if kind get clusters 2>/dev/null | grep -q "^${CLUSTER_NAME}$"; then
  check_pass "Kind cluster '${CLUSTER_NAME}' exists"
else
  check_fail "Kind cluster '${CLUSTER_NAME}' not found — run ./scripts/setup-cluster.sh"
fi

if kubectl cluster-info --context "kind-${CLUSTER_NAME}" >/dev/null 2>&1; then
  check_pass "kubectl can reach the cluster"
else
  check_fail "kubectl cannot reach cluster — is Docker running?"
fi

# ── 2. Tekton Pipelines ──────────────────────────────────────────
echo ""
echo -e "${BOLD}Tekton Pipelines${RESET}"
if kubectl get deploy tekton-pipelines-controller -n tekton-pipelines >/dev/null 2>&1; then
  READY=$(kubectl get deploy tekton-pipelines-controller -n tekton-pipelines \
    -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
  if [ "${READY}" = "1" ]; then
    VERSION=$(kubectl get deploy tekton-pipelines-controller -n tekton-pipelines \
      -o jsonpath='{.metadata.labels.app\.kubernetes\.io/version}' 2>/dev/null || echo "unknown")
    check_pass "Pipelines controller ready (${VERSION})"
  else
    check_fail "Pipelines controller not ready (replicas: ${READY})"
  fi
else
  check_fail "Tekton Pipelines not installed"
fi

if kubectl get deploy tekton-pipelines-webhook -n tekton-pipelines >/dev/null 2>&1; then
  READY=$(kubectl get deploy tekton-pipelines-webhook -n tekton-pipelines \
    -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
  if [ "${READY}" = "1" ]; then
    check_pass "Pipelines webhook ready"
  else
    check_fail "Pipelines webhook not ready (replicas: ${READY})"
  fi
else
  check_fail "Tekton Pipelines webhook not installed"
fi

ALPHA=$(kubectl get configmap feature-flags -n tekton-pipelines \
  -o jsonpath='{.data.enable-api-fields}' 2>/dev/null || echo "")
if [ "${ALPHA}" = "alpha" ]; then
  check_pass "Alpha API fields enabled (hermetic execution)"
else
  check_warn "Alpha API fields not set to 'alpha' (current: '${ALPHA}') — hermetic execution won't work"
fi

# ── 3. Tekton Chains ─────────────────────────────────────────────
echo ""
echo -e "${BOLD}Tekton Chains${RESET}"
if kubectl get deploy tekton-chains-controller -n tekton-chains >/dev/null 2>&1; then
  READY=$(kubectl get deploy tekton-chains-controller -n tekton-chains \
    -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
  if [ "${READY}" = "1" ]; then
    VERSION=$(kubectl get deploy tekton-chains-controller -n tekton-chains \
      -o jsonpath='{.metadata.labels.app\.kubernetes\.io/version}' 2>/dev/null || echo "unknown")
    check_pass "Chains controller ready (${VERSION})"
  else
    check_fail "Chains controller not ready (replicas: ${READY})"
  fi
else
  check_fail "Tekton Chains not installed"
fi

if kubectl get secret signing-secrets -n tekton-chains >/dev/null 2>&1; then
  check_pass "Cosign signing secret exists"
else
  check_fail "Cosign signing secret missing — run setup-cluster.sh"
fi

# ── 4. Tekton Resources ──────────────────────────────────────────
echo ""
echo -e "${BOLD}Tekton Resources${RESET}"
for resource in "task/git-clone" "task/ko-build" "pipeline/reproducible-build"; do
  if kubectl get "${resource}" >/dev/null 2>&1; then
    check_pass "${resource} exists"
  else
    check_fail "${resource} not found — run setup-cluster.sh"
  fi
done

# ── 5. Stale PipelineRuns ────────────────────────────────────────
echo ""
echo -e "${BOLD}Cleanup${RESET}"
EXISTING_RUNS=$(kubectl get pipelinerun -l app.kubernetes.io/part-of=reproducible-build-demo \
  --no-headers 2>/dev/null | wc -l | tr -d ' ')
if [ "${EXISTING_RUNS}" = "0" ]; then
  check_pass "No stale PipelineRuns from previous demos"
else
  check_warn "${EXISTING_RUNS} PipelineRun(s) from previous demos — consider: kubectl delete pipelinerun -l app.kubernetes.io/part-of=reproducible-build-demo"
fi

# ── 6. Tools ─────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}Local Tools${RESET}"
for cmd in kind kubectl cosign tkn; do
  if command -v "${cmd}" >/dev/null 2>&1; then
    check_pass "${cmd} available"
  else
    check_warn "${cmd} not found (optional for demo but useful for troubleshooting)"
  fi
done

# ── Summary ──────────────────────────────────────────────────────
echo ""
echo "─────────────────────────────────────────"
if [ ${FAIL} -eq 0 ]; then
  echo -e "${GREEN}${BOLD}  READY${RESET}  ${PASS} checks passed, ${WARN} warnings"
  echo ""
  echo "  You're good to go. Run: ./scripts/run-demo.sh"
else
  echo -e "${RED}${BOLD}  NOT READY${RESET}  ${FAIL} checks failed, ${WARN} warnings"
  echo ""
  echo "  Fix the failures above, then re-run this script."
fi
echo "─────────────────────────────────────────"
echo ""
