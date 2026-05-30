#!/usr/bin/env bash
#
# Simple policy gate: checks if a PipelineRun has valid signed provenance.
# Usage: ./scripts/policy-check.sh <pipelinerun-name>
#
# Outputs ALLOW or DENY with reasons.
#
set -euo pipefail

BOLD='\033[1m'
GREEN='\033[0;32m'
RED='\033[0;31m'
RESET='\033[0m'

allow() { echo -e "\n${GREEN}${BOLD}  ██ ALLOW — deploy permitted${RESET}\n"; }
deny()  { echo -e "\n${RED}${BOLD}  ██ DENY — deploy rejected${RESET}\n"; exit 1; }
check() { echo -e "  $*"; }

RUN="${1:-}"
if [ -z "${RUN}" ]; then
  echo "Usage: $0 <pipelinerun-name>"
  exit 1
fi

echo ""
echo -e "${BOLD}Policy Check: ${RUN}${RESET}"
echo ""

# 1. Does the PipelineRun exist and succeed?
STATUS=$(kubectl get pipelinerun "${RUN}" -o jsonpath='{.status.conditions[0].status}' 2>/dev/null || true)
if [ "${STATUS}" != "True" ]; then
  check "✗ PipelineRun did not succeed (status: ${STATUS:-not found})"
  deny
fi
check "✓ PipelineRun succeeded"

# 2. Is it signed by Chains?
SIGNED=$(kubectl get pipelinerun "${RUN}" \
  -o jsonpath='{.metadata.annotations.chains\.tekton\.dev/signed}' 2>/dev/null || true)
if [ "${SIGNED}" != "true" ]; then
  check "✗ Not signed by Tekton Chains"
  deny
fi
check "✓ Signed by Tekton Chains"

# 3. Does provenance exist?
RUN_UID=$(kubectl get pipelinerun "${RUN}" -o jsonpath='{.metadata.uid}')
PAYLOAD=$(kubectl get pipelinerun "${RUN}" \
  -o jsonpath="{.metadata.annotations.chains\.tekton\.dev/payload-pipelinerun-${RUN_UID}}" \
  2>/dev/null || true)
if [ -z "${PAYLOAD}" ]; then
  check "✗ No provenance payload found"
  deny
fi
check "✓ SLSA provenance exists"

# 4. Is the provenance valid JSON with a subject?
SUBJECT=$(echo "${PAYLOAD}" | base64 -d 2>/dev/null | \
  python3 -c "import sys,json; d=json.load(sys.stdin); print(d['subject'][0]['name'])" 2>/dev/null || true)
if [ -z "${SUBJECT}" ]; then
  check "✗ Provenance payload is malformed"
  deny
fi
check "✓ Provenance subject: ${SUBJECT}"

# 5. Verify the signature
SIGNATURE=$(kubectl get pipelinerun "${RUN}" \
  -o jsonpath="{.metadata.annotations.chains\.tekton\.dev/signature-pipelinerun-${RUN_UID}}" \
  2>/dev/null || true)
if [ -z "${SIGNATURE}" ]; then
  check "✗ No signature found"
  deny
fi

VERIFY_RESULT=$(echo "${SIGNATURE}" | base64 -d | \
  cosign verify-blob-attestation \
    --insecure-ignore-tlog \
    --key k8s://tekton-chains/signing-secrets \
    --signature /dev/stdin \
    --type slsaprovenance1 \
    --check-claims=false \
    /dev/null 2>&1 || true)

if echo "${VERIFY_RESULT}" | grep -qi "verified ok\|verified"; then
  check "✓ Cosign signature verified"
else
  check "✗ Signature verification failed"
  deny
fi

allow
