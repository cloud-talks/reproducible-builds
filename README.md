# From Pipelines to Provenance: Reproducible Builds with Tekton

Companion repo for the [Open Source Summit India 2026](https://events.linuxfoundation.org/open-source-summit-india/) talk.
Clone it, run it, and see reproducible builds in action.

**Speakers:** Shubham Bhardwaj & Divyanshu Agrawal, Red Hat

## What This Proves

Two independent Tekton PipelineRuns, building the same Go source code, produce
**byte-identical container images** every time. Tekton Chains then generates
SLSA-compliant provenance for each build and signs it cryptographically.

## Prerequisites

| Tool | Version |
|------|---------|
| [Docker](https://docs.docker.com/get-docker/) or [Podman](https://podman.io/docs/installation) | Docker 20.10+ / Podman 4.0+ |
| [kind](https://kind.sigs.k8s.io/) | v0.20+ |
| [kubectl](https://kubernetes.io/docs/tasks/tools/) | v1.27+ |
| [cosign](https://github.com/sigstore/cosign) | v2.2+ |
| [tkn](https://tekton.dev/docs/cli/) | v0.33+ |

On macOS, all tools are available via [Homebrew](https://brew.sh/):
`brew install kind kubectl cosign tektoncd-cli`

The demo pushes images to [ttl.sh](https://ttl.sh), a free anonymous container
registry where images auto-expire after a few hours. No registry account is
needed. Cluster pods need outbound internet access to reach GitHub and ttl.sh.

## Quick Start

```bash
# 1. Create a Kind cluster with Tekton Pipelines + Chains
./scripts/setup-cluster.sh

# 2. Verify the cluster is healthy
./scripts/pre-flight.sh

# 3. Run the demo (two builds, compare digests, verify provenance)
./scripts/run-demo.sh

# 4. Clean up
./scripts/teardown.sh
```

To run a simulated demo without a cluster: `DRY_RUN=true ./scripts/run-demo.sh`

## Before the Demo

The PipelineRun YAMLs (`tekton/runs/run-*.yaml`) are pre-configured to clone
from `https://github.com/cloud-talks/reproducible-builds` at a pinned commit
SHA. If you fork this repo or want to build from a different commit, update
both run files:

```bash
# Update the commit SHA
COMMIT=$(git rev-parse HEAD)
sed -i "s/584202d2866814fc726af1465ca317238774676a/${COMMIT}/g" tekton/runs/run-*.yaml  # Linux
sed -i '' "s/584202d2866814fc726af1465ca317238774676a/${COMMIT}/g" tekton/runs/run-*.yaml  # macOS

# If using a different repository, also update the git-url param in both run files.
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
  pre-flight.sh        Pre-demo health check
  run-demo.sh          Execute builds, compare, verify
  teardown.sh          Delete the Kind cluster
```

## How Reproducibility Is Achieved

Each source of non-determinism is explicitly eliminated:

| Source of Non-Determinism | How It's Eliminated | Where |
|---|---|---|
| **Timestamps** in image config/layers | `SOURCE_DATE_EPOCH=0`; ko omits layer timestamps by default | ko-build Task, ko defaults |
| **Go build ID** varies per invocation | `-ldflags='-buildid='` | `.ko.yaml` |
| **Filesystem paths** in binary | `-trimpath` | `.ko.yaml` |
| **Base image drift** | Pinned by `sha256:` digest | `.ko.yaml` |
| **Source code drift** | Pinned git commit SHA | PipelineRun params |
| **File ordering** in layers | ko sorts layers by content digest | ko defaults |

`.ko.yaml` also includes `-ldflags='-s -w'` to strip debug symbols and reduce
image size, though this is an optimization rather than a reproducibility fix.

The build tool (ko) handles the determinism. Tekton's role is the layer around
it: parameterized pipelines make inputs explicit and repeatable, structured
results give Chains a machine-readable contract, and Chains generates signed
SLSA provenance automatically — no extra pipeline step needed. That's the
"pipelines to provenance" arc.

## Tekton Concepts Used

### Type-Hinted Results (for Tekton Chains)

Chains discovers build inputs and outputs through specially named results:

- `CHAINS-GIT_URL` / `CHAINS-GIT_COMMIT` — source provenance
- `IMAGE_URL` / `IMAGE_DIGEST` — output artifact identification

### SLSA Provenance

Chains generates SLSA v1 provenance that records:
- **What** was built (image digest)
- **From what** (git URL + commit)
- **By whom** (builder identity)
- **How** (pipeline/task configuration)

The Chains configuration uses the `slsa/v2alpha4` formatter — that version
refers to the Chains formatter, not the SLSA spec version. The output conforms
to [SLSA Provenance v1](https://slsa.dev/provenance/v1).

### Hermetic Execution

This demo does not use hermetic execution, but Tekton supports it as an
alpha feature. Adding this annotation to a TaskRun disables network access
during the build:

```yaml
annotations:
  experimental.tekton.dev/execution-mode: hermetic
```

Using hermetic execution requires a pipeline structured to fetch dependencies
in a separate non-hermetic step before the hermetic build step. See
[TEP-0025](https://github.com/tektoncd/community/blob/main/teps/0025-hermekton.md)
and the [Tekton hermetic execution docs](https://tekton.dev/docs/pipelines/hermetic/)
for details.

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
- [SLSA Framework Specification (v1.2)](https://slsa.dev/spec/v1.2/)
- [TEP-0025: Hermekton — Hermetic Builds in Tekton](https://github.com/tektoncd/community/blob/main/teps/0025-hermekton.md)
- [Tekton Chains SLSA Provenance](https://github.com/tektoncd/chains/blob/main/docs/slsa-provenance.md)
- [ko: Easy Go Containers](https://ko.build/)
- [Go Blog: Perfectly Reproducible Builds](https://go.dev/blog/rebuild)
- [SOURCE_DATE_EPOCH Spec](https://reproducible-builds.org/specs/source-date-epoch/)
- [arXiv:2602.17678 — Docker Reproducibility Study](https://arxiv.org/abs/2602.17678)
