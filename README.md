# From Pipelines to Provenance: Reproducible Builds With Tekton

Live demo for [Open Source Summit Mumbai](https://events.linuxfoundation.org/open-source-summit-india/).

## What This Proves

Two independent Tekton PipelineRuns, building the same Go source code, produce
**byte-identical container images** every time. Tekton Chains then generates
SLSA-compliant provenance for each build and signs it cryptographically.

## Prerequisites

| Tool | Version | Install |
|------|---------|---------|
| [kind](https://kind.sigs.k8s.io/) | v0.20+ | `brew install kind` |
| [kubectl](https://kubernetes.io/docs/tasks/tools/) | v1.27+ | `brew install kubectl` |
| [cosign](https://github.com/sigstore/cosign) | v2.0+ | `brew install cosign` |
| [tkn](https://tekton.dev/docs/cli/) | v0.33+ | `brew install tektoncd-cli` |

## Quick Start

```bash
# 1. Create a Kind cluster with Tekton Pipelines + Chains
./scripts/setup-cluster.sh

# 2. Run the demo (two builds, compare digests, verify provenance)
./scripts/run-demo.sh

# 3. Clean up
./scripts/teardown.sh
```

## Before the Demo

You must push the `demo-app/` to a public Git repository and update the
PipelineRun YAMLs with the actual commit SHA:

```bash
# Push demo-app to your repo, then:
COMMIT=$(git rev-parse HEAD)
sed -i '' "s/REPLACE_WITH_COMMIT_SHA/${COMMIT}/g" tekton/runs/run-*.yaml
```

## Project Structure

```
demo-app/
  main.go              Go HTTP server (~35 lines)
  go.mod               Go module definition
  .ko.yaml             ko config with reproducibility flags

tekton/
  tasks/
    git-clone.yaml     Task: clone repo, emit CHAINS-GIT_URL/COMMIT
    ko-build.yaml      Task: build with ko, emit IMAGE_URL/DIGEST
  pipelines/
    reproducible-build.yaml   Pipeline: clone → build
  runs/
    run-1.yaml         First PipelineRun
    run-2.yaml         Second PipelineRun (identical params)

scripts/
  setup-cluster.sh     Kind + Tekton + Chains + cosign setup
  run-demo.sh          Execute builds, compare, verify
  teardown.sh          Delete the Kind cluster
```

## How Reproducibility Is Achieved

Each source of non-determinism is explicitly eliminated:

| Source of Non-Determinism | How It's Eliminated | Where |
|---|---|---|
| **Timestamps** in image config | `SOURCE_DATE_EPOCH=0` | ko-build Task |
| **Timestamps** in image layers | ko sets epoch by default | ko defaults |
| **Go build ID** varies per machine | `-ldflags='-buildid='` | `.ko.yaml` |
| **Filesystem paths** in binary | `-trimpath` | `.ko.yaml` |
| **Debug symbols** | `-ldflags='-s -w'` | `.ko.yaml` |
| **Base image drift** | Pinned by `sha256:` digest | `.ko.yaml` |
| **Source code drift** | Pinned git commit SHA | PipelineRun params |
| **Network-fetched deps** | Hermetic execution (optional) | TaskRun annotation |
| **File ordering** in layers | ko sorts layers by content digest | ko defaults |

## Key Tekton Concepts Demonstrated

### Type-Hinted Results (for Tekton Chains)

Chains discovers build inputs and outputs through specially named results:

- `CHAINS-GIT_URL` / `CHAINS-GIT_COMMIT` — source provenance
- `IMAGE_URL` / `IMAGE_DIGEST` — output artifact identification

### Hermetic Execution (optional)

Add this annotation to a TaskRun to disable network access:

```yaml
annotations:
  experimental.tekton.dev/execution-mode: hermetic
```

Requires `enable-api-fields: "alpha"` in the `feature-flags` ConfigMap.
The setup script enables this automatically.

### SLSA Provenance

Chains generates SLSA v1.0 provenance (`slsa/v2alpha4` formatter) that records:
- **What** was built (image digest)
- **From what** (git URL + commit)
- **By whom** (builder identity)
- **How** (pipeline/task configuration)

## Troubleshooting

**PipelineRun stuck in pending:**
```bash
kubectl get pipelinerun -w
kubectl describe pipelinerun <name>
```

**Chains not signing:**
```bash
kubectl logs -n tekton-chains -l app=tekton-chains-controller --tail=50
kubectl get configmap chains-config -n tekton-chains -o yaml
```

**Digests don't match:**
Check that both runs use identical params. Inspect the build logs:
```bash
tkn pipelinerun logs <run-name>
```

Common causes of non-reproducibility:
- Different `SOURCE_DATE_EPOCH` values
- Missing `-buildid=` in ldflags
- Base image referenced by tag instead of digest
- Git revision is a branch name instead of a commit SHA

## References

- [Reproducible Builds](https://reproducible-builds.org/)
- [SLSA Specification](https://slsa.dev/spec/v1.2/)
- [TEP-0025: Hermetic Builds](https://github.com/tektoncd/community/blob/main/teps/0025-hermekton.md)
- [Tekton Chains SLSA Provenance](https://github.com/tektoncd/chains/blob/main/docs/slsa-provenance.md)
- [ko: Easy Go Containers](https://ko.build/)
- [Go Blog: Perfectly Reproducible Builds](https://go.dev/blog/rebuild)
- [SOURCE_DATE_EPOCH Spec](https://reproducible-builds.org/specs/source-date-epoch/)
- [arXiv:2602.17678 — Docker Reproducibility Study](https://arxiv.org/abs/2602.17678)
