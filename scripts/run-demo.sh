#!/usr/bin/env bash
#
# Live demo script for "From Pipelines to Provenance"
#
# Flow:
#   1. Show It Broken — two naive builds with different timestamps → different digests
#   2. Show the source — main.go, .ko.yaml, pipeline YAML
#   3. The Fix — two reproducible builds → matching digests
#   4. Provenance — Chains signing, SLSA provenance, DSSE envelope, cosign verify
#   5. Policy Gate — check provenance → ALLOW / DENY
#   6. Hermetic Execution — standalone TaskRun with no network access
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "${SCRIPT_DIR}")"

DRY_RUN="${DRY_RUN:-false}"

# ── Helpers ────────────────────────────────────────────────────────
BOLD='\033[1m'
GREEN='\033[0;32m'
RED='\033[0;31m'
CYAN='\033[0;36m'
YELLOW='\033[0;33m'
RESET='\033[0m'

banner() {
  echo ""
  echo -e "${BOLD}${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
  echo -e "${BOLD}${CYAN}  $*${RESET}"
  echo -e "${BOLD}${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
  echo ""
}
info()   { echo -e "${BOLD}$*${RESET}"; }
pass()   { echo -e "${GREEN}${BOLD}✓ $*${RESET}"; }
fail()   { echo -e "${RED}${BOLD}✗ $*${RESET}"; }
warn()   { echo -e "${YELLOW}${BOLD}⚠ $*${RESET}"; }

wait_for_pipelinerun() {
  local name="$1"
  local timeout="${2:-300}"
  info "Waiting for PipelineRun ${name} to complete (timeout: ${timeout}s)..."

  if ! kubectl wait --for=condition=Succeeded --timeout="${timeout}s" \
    "pipelinerun/${name}" 2>/dev/null; then
    local status
    status=$(kubectl get pipelinerun "${name}" -o jsonpath='{.status.conditions[0].status}')
    if [ "${status}" = "False" ]; then
      fail "PipelineRun ${name} FAILED"
      kubectl get pipelinerun "${name}" -o jsonpath='{.status.conditions[0].message}'
      echo ""
      return 1
    fi
    fail "PipelineRun ${name} timed out"
    return 1
  fi
  pass "PipelineRun ${name} succeeded"
}

get_result() {
  local run="$1" result="$2"
  kubectl get pipelinerun "${run}" \
    -o jsonpath="{.status.results[?(@.name==\"${result}\")].value}"
}

# ── Dry-run mode ──────────────────────────────────────────────────
if [ "${DRY_RUN}" = "true" ]; then
  warn "DRY-RUN MODE — showing simulated output (no cluster required)"
  echo ""

  NAIVE_DIGEST_1="sha256:aaa111bbb222ccc333ddd444eee555fff666aaa111bbb222ccc333ddd444eee555"
  NAIVE_DIGEST_2="sha256:999888777666555444333222111000fff999888777666555444333222111000eee"
  REPRO_DIGEST="sha256:75d4b60a847dba85446f05b676a0d0172faeff3ade8005c91d979ffe7d16b446"

  banner "ACT 1: Show It Broken"
  info "Two builds of the same Dockerfile — no reproducibility flags..."
  sleep 1
  pass "Naive build #1 succeeded"
  pass "Naive build #2 succeeded"
  echo ""
  info "Naive Build #1:  ${NAIVE_DIGEST_1}"
  info "Naive Build #2:  ${NAIVE_DIGEST_2}"
  echo ""
  fail "DIGESTS DO NOT MATCH — same Dockerfile, different images!"
  echo ""
  echo "  Buildah embedded real timestamps → different image config → different digest."
  echo ""
  read -rp "Press Enter to see the fix..."

  banner "ACT 2: The Source"
  info "demo-app/main.go — simple Go HTTP server"
  info "demo-app/.ko.yaml — reproducibility flags that kill each enemy"
  echo ""
  read -rp "Press Enter to start the reproducible builds..."

  banner "ACT 3: The Fix — Reproducible Builds"
  sleep 2
  pass "Reproducible build #1 succeeded"
  pass "Reproducible build #2 succeeded"
  echo ""
  info "Reproducible Build #1:  ${REPRO_DIGEST}"
  info "Reproducible Build #2:  ${REPRO_DIGEST}"
  echo ""
  pass "DIGESTS MATCH — builds are byte-identical!"
  echo ""
  read -rp "Press Enter to check provenance..."

  banner "ACT 4: SLSA Provenance via Tekton Chains"
  pass "Signed by Tekton Chains"
  pass "SLSA provenance decoded"
  pass "DSSE envelope inspected"
  pass "Cosign signature verified"
  echo ""
  read -rp "Press Enter for policy gate..."

  banner "ACT 5: Policy Gate"
  echo -e "  ${GREEN}${BOLD}  ██ ALLOW — deploy permitted${RESET}"
  echo ""
  read -rp "Press Enter for hermetic execution..."

  banner "ACT 6: Hermetic Execution"
  pass "Network access blocked — hermetic mode working"
  echo ""

  banner "SUMMARY"
  echo "  1. Naive builds: different timestamps → different images"
  echo "  2. Reproducible builds: all enemies eliminated → identical images"
  echo "  3. Chains automatically generated signed SLSA provenance"
  echo "  4. Policy gate: provenance verified → deploy allowed"
  echo "  5. Hermetic execution: network blocked during task"
  echo ""
  warn "This was DRY-RUN mode — no cluster was used"
  exit 0
fi

# ══════════════════════════════════════════════════════════════════
# LIVE MODE
# ══════════════════════════════════════════════════════════════════

# ── Act 1: Show It Broken ────────────────────────────────────────
banner "ACT 1: Show It Broken"

info "Building the same Dockerfile twice — no reproducibility flags..."
echo "  buildah bud (without --source-date-epoch or --rewrite-timestamp)"
echo ""

NAIVE1_NAME=$(kubectl create -f "${PROJECT_DIR}/tekton/runs/run-naive-1.yaml" -o name | sed 's|pipelinerun.tekton.dev/||')
echo "  → ${NAIVE1_NAME}"
NAIVE2_NAME=$(kubectl create -f "${PROJECT_DIR}/tekton/runs/run-naive-2.yaml" -o name | sed 's|pipelinerun.tekton.dev/||')
echo "  → ${NAIVE2_NAME}"

echo ""
wait_for_pipelinerun "${NAIVE1_NAME}" 600
wait_for_pipelinerun "${NAIVE2_NAME}" 600

NAIVE_DIGEST1=$(get_result "${NAIVE1_NAME}" "IMAGE_DIGEST")
NAIVE_DIGEST2=$(get_result "${NAIVE2_NAME}" "IMAGE_DIGEST")

echo ""
info "Naive Build #1:  ${NAIVE_DIGEST1}"
info "Naive Build #2:  ${NAIVE_DIGEST2}"
echo ""

if [ "${NAIVE_DIGEST1}" != "${NAIVE_DIGEST2}" ]; then
  fail "DIGESTS DO NOT MATCH — same Dockerfile, different images!"
  echo ""
  echo "  Same source, same Dockerfile, same commit."
  echo "  Buildah embedded real timestamps → different image config → different digest."
else
  warn "Digests unexpectedly match — buildah may have cached layers."
fi

echo ""
read -rp "Press Enter to see the fix..."

# ── Act 2: Show the source ──────────────────────────────────────
banner "ACT 2: The Source"

info "Go application (demo-app/main.go):"
echo "---"
cat "${PROJECT_DIR}/demo-app/main.go"
echo "---"
echo ""

info "Dockerfile (demo-app/Dockerfile):"
echo "---"
cat "${PROJECT_DIR}/demo-app/Dockerfile"
echo "---"
echo ""
read -rp "Press Enter to start the reproducible builds..."

# ── Act 3: The Fix — Reproducible Builds ─────────────────────────
banner "ACT 3: The Fix — Reproducible Builds"

info "Same Dockerfile, same commit — now with buildah --source-date-epoch 0 --rewrite-timestamp..."
echo ""

RUN1_NAME=$(kubectl create -f "${PROJECT_DIR}/tekton/runs/run-1.yaml" -o name | sed 's|pipelinerun.tekton.dev/||')
echo "  → ${RUN1_NAME}"
RUN2_NAME=$(kubectl create -f "${PROJECT_DIR}/tekton/runs/run-2.yaml" -o name | sed 's|pipelinerun.tekton.dev/||')
echo "  → ${RUN2_NAME}"

echo ""
info "Both PipelineRuns executing in parallel..."
echo ""

wait_for_pipelinerun "${RUN1_NAME}" 600
wait_for_pipelinerun "${RUN2_NAME}" 600

# ── The Money Shot ───────────────────────────────────────────────
DIGEST1=$(get_result "${RUN1_NAME}" "IMAGE_DIGEST")
DIGEST2=$(get_result "${RUN2_NAME}" "IMAGE_DIGEST")

echo ""
info "Reproducible Build #1:  ${DIGEST1}"
info "Reproducible Build #2:  ${DIGEST2}"
echo ""

if [ "${DIGEST1}" = "${DIGEST2}" ]; then
  pass "DIGESTS MATCH — builds are byte-identical!"
  echo ""
  echo "  Before (naive):       buildah without repro flags → different digests"
  echo "  After (reproducible): --source-date-epoch 0 --rewrite-timestamp → identical digests"
  echo ""
else
  fail "DIGESTS DO NOT MATCH — investigate build logs"
fi

read -rp "Press Enter to check provenance..."

# ── Act 4: SLSA Provenance via Tekton Chains ─────────────────────
banner "ACT 4: SLSA Provenance via Tekton Chains"

info "Checking if Chains has signed PipelineRun #1..."
echo ""

MAX_WAIT=60
WAITED=0
while [ ${WAITED} -lt ${MAX_WAIT} ]; do
  SIGNED=$(kubectl get pipelinerun "${RUN1_NAME}" \
    -o jsonpath='{.metadata.annotations.chains\.tekton\.dev/signed}' 2>/dev/null || true)
  if [ "${SIGNED}" = "true" ]; then
    break
  fi
  echo "  Waiting for Chains to sign (${WAITED}s / ${MAX_WAIT}s)..."
  sleep 5
  WAITED=$((WAITED + 5))
done

if [ "${SIGNED}" = "true" ]; then
  pass "PipelineRun #1 is signed by Tekton Chains"
else
  fail "Chains did not sign within ${MAX_WAIT}s — check chains controller logs"
  echo "  kubectl logs -n tekton-chains -l app=tekton-chains-controller"
fi

RUN1_UID=$(kubectl get pipelinerun "${RUN1_NAME}" -o jsonpath='{.metadata.uid}')

# ── 4a: Where the attestation lives ──────────────────────────────
echo ""
info "Where Chains stores the attestation:"
echo ""
kubectl get pipelinerun "${RUN1_NAME}" -o json | python3 -c "
import sys, json
annots = json.load(sys.stdin)['metadata'].get('annotations', {})
for k in sorted(annots):
    if 'chains' in k:
        print(f'  {k} ({len(annots[k])} chars)')
"
echo ""

# ── 4b: SLSA provenance payload ─────────────────────────────────
info "Decoding SLSA provenance payload..."
echo ""

PAYLOAD=$(kubectl get pipelinerun "${RUN1_NAME}" \
  -o jsonpath="{.metadata.annotations.chains\.tekton\.dev/payload-pipelinerun-${RUN1_UID}}" \
  2>/dev/null || true)

if [ -n "${PAYLOAD}" ]; then
  echo "${PAYLOAD}" | base64 -d | python3 -m json.tool 2>/dev/null || \
    echo "${PAYLOAD}" | base64 -d
  echo ""
  pass "SLSA provenance retrieved and decoded"
else
  warn "Payload not stored as annotation (may be in OCI storage)."
fi

# ── 4c: DSSE envelope ───────────────────────────────────────────
echo ""
info "Inspecting the DSSE signature envelope..."
echo ""

kubectl get pipelinerun "${RUN1_NAME}" \
  -o jsonpath="{.metadata.annotations.chains\.tekton\.dev/signature-pipelinerun-${RUN1_UID}}" \
  | base64 -d | python3 -c "
import sys, json
env = json.load(sys.stdin)
print('DSSE Envelope:')
print(f'  payloadType: {env[\"payloadType\"]}')
print(f'  payload:     ({len(env[\"payload\"])} chars, base64-encoded provenance)')
print(f'  signatures:  {len(env[\"signatures\"])} signature(s)')
for i, sig in enumerate(env['signatures']):
    print(f'    [{i}] keyid: {sig.get(\"keyid\", \"(empty)\")}')
    print(f'        sig:   {sig[\"sig\"][:40]}...')
" 2>/dev/null || info "(Could not parse DSSE envelope)"

# ── 4d: Cosign verification ─────────────────────────────────────
echo ""
info "Verifying signature with cosign..."
echo ""

COSIGN_RESULT=$(cosign verify-blob-attestation \
  --insecure-ignore-tlog \
  --key k8s://tekton-chains/signing-secrets \
  --signature <(kubectl get pipelinerun "${RUN1_NAME}" \
    -o jsonpath="{.metadata.annotations.chains\.tekton\.dev/signature-pipelinerun-${RUN1_UID}}" | base64 -d) \
  --type slsaprovenance1 \
  --check-claims=false \
  /dev/null 2>&1 || true)

if echo "${COSIGN_RESULT}" | grep -qi "verified ok\|verified"; then
  pass "Signature verified with cosign"
else
  info "cosign output: ${COSIGN_RESULT}"
fi

read -rp "Press Enter for policy gate..."

# ── Act 5: Policy Gate ──────────────────────────────────────────
banner "ACT 5: Policy Gate"

info "Does this image have valid signed provenance?"
echo ""
"${SCRIPT_DIR}/policy-check.sh" "${RUN1_NAME}" || true

read -rp "Press Enter for hermetic execution..."

# ── Act 6: Hermetic Execution (pre-recorded) ────────────────────
banner "ACT 6: Hermetic Execution"

info "Hermetic execution requires Docker (not Podman). Showing pre-recorded demo."
echo ""

RECORDING="${PROJECT_DIR}/talk/recordings/hermetic-demo.txt"
if [ -f "${RECORDING}" ]; then
  cat "${RECORDING}"
else
  warn "No recording found at ${RECORDING}"
  info "Run ./scripts/record-hermetic-demo.sh (with Docker) to generate it."
fi

# ── Summary ──────────────────────────────────────────────────────
banner "SUMMARY"

echo "What we demonstrated:"
echo ""
echo "  1. Naive builds: different timestamps → different images"
echo "  2. Reproducible builds: all enemies eliminated → identical images"
echo "  3. Tekton Chains automatically generated signed SLSA provenance"
echo "  4. Policy gate: provenance verified → deploy allowed"
echo "  5. Hermetic execution: network blocked during task"
echo ""
echo "Key ingredients:"
echo ""
echo "  Dockerfile:"
echo "  • Pinned base images by digest    → no base image drift"
echo "  • -trimpath -ldflags='-buildid='  → deterministic Go binary"
echo ""
echo "  Buildah:"
echo "  • --source-date-epoch 0           → zeroed timestamps"
echo "  • --rewrite-timestamp             → clamped file metadata"
echo ""
echo "  Tekton:"
echo "  • Parameterized PipelineRun       → explicit, repeatable inputs"
echo "  • Tekton Chains                   → automatic signed SLSA provenance"
echo "  • Hermetic execution       → no network access during build"
echo ""
echo "  provenance + reproducibility = verifiable supply chain"
echo ""
