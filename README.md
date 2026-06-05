# From Pipelines to Provenance: Reproducible Builds with Tekton

Companion repo for the [Open Source Summit India 2026](https://events.linuxfoundation.org/open-source-summit-india/) talk.
Clone it, run it, and see reproducible builds in action.

**Speakers:** Shubham Bhardwaj & Divyanshu Agrawal, Red Hat

## What This Proves

Two independent Tekton PipelineRuns, building the same Dockerfile, produce
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

# 3. Run the demo (naive builds → reproducible builds → provenance → policy gate)
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
  Dockerfile           Multi-stage build with reproducibility flags

tekton/
  tasks/
    git-clone.yaml     Task: clone repo, emit CHAINS-GIT_URL/COMMIT
    buildah-build.yaml Task: build with buildah, emit IMAGE_URL/DIGEST
    verify-hermetic.yaml  Task: hermetic execution demo
  pipelines/
    reproducible-build.yaml   Pipeline: clone → build
  runs/
    run-1.yaml         Reproducible PipelineRun #1
    run-2.yaml         Reproducible PipelineRun #2 (identical params)
    run-naive-1.yaml   Naive PipelineRun #1 (no repro flags)
    run-naive-2.yaml   Naive PipelineRun #2 (no repro flags)
    run-hermetic.yaml  Hermetic execution TaskRun

scripts/
  setup-cluster.sh     Kind + Tekton + Chains + cosign setup
  pre-flight.sh        Pre-demo health check
  run-demo.sh          Full demo: naive → reproducible → provenance → policy
  policy-check.sh      Policy gate: checks provenance → ALLOW / DENY
  record-hermetic-demo.sh  Record hermetic demo (requires Docker)
  teardown.sh          Delete the Kind cluster

ko/                    Reference: ko-based approach (alternative to Dockerfile)
  .ko.yaml             ko config with reproducibility flags
  ko-build.yaml        Tekton Task for ko builds
```

## How Reproducibility Is Achieved

Each source of non-determinism is explicitly eliminated:

| Source of Non-Determinism | How It's Eliminated | Where |
|---|---|---|
| **Timestamps** in image config/layers | `buildah --source-date-epoch 0 --rewrite-timestamp` | buildah-build Task |
| **Go build ID** varies per invocation | `-ldflags='-buildid='` | Dockerfile |
| **Filesystem paths** in binary | `-trimpath` | Dockerfile |
| **Base image drift** | Both stages pinned by `sha256:` digest | Dockerfile |
| **Source code drift** | Pinned git commit SHA | PipelineRun params |

The Dockerfile handles the application-level determinism (Go build flags,
pinned base images). Buildah handles the image-level determinism (timestamp
clamping via `--source-date-epoch` and `--rewrite-timestamp`). Tekton handles
the orchestration and provenance — parameterized pipelines make inputs explicit,
structured results give Chains a machine-readable contract, and Chains generates
signed SLSA provenance automatically. That's the "pipelines to provenance" arc.

## The Naive vs Reproducible Contrast

The pipeline has a `reproducible` parameter (default `"true"`):

- **Naive builds** (`reproducible: "false"`): buildah runs without timestamp
  clamping. Real timestamps are embedded in image layers. Two builds of the
  same Dockerfile produce different digests.
- **Reproducible builds** (`reproducible: "true"`): buildah runs with
  `--source-date-epoch 0 --rewrite-timestamp`. Timestamps are clamped to
  epoch zero. Two builds produce identical digests.

Same Dockerfile, same source, same commit. The only difference is two buildah
flags.

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

Tekton supports hermetic execution as an alpha feature. Adding this annotation
to a TaskRun disables network access:

```yaml
annotations:
  experimental.tekton.dev/execution-mode: hermetic
```

The demo includes a standalone hermetic TaskRun (`run-hermetic.yaml`) that
proves network isolation works. Hermetic execution requires Docker (not
Podman) as the container runtime. Use `./scripts/record-hermetic-demo.sh`
to pre-record the demo.

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
Check that both runs use identical params and `reproducible: "true"`.
Inspect the build logs:
```bash
tkn pipelinerun logs <run-name>
```

Common causes of non-reproducibility:
- `reproducible` param set to `"false"` (missing `--source-date-epoch`)
- Missing `-buildid=` or `-trimpath` in Dockerfile `go build` command
- Base image referenced by tag instead of digest
- Git revision is a branch name instead of a commit SHA

**Buildah storage errors:**
The buildah task uses `--storage-driver=vfs` for compatibility inside Kind pods.
If you see storage errors, ensure the `container-storage` emptyDir volume is
mounted at `/var/lib/containers`.

## References

- [Reproducible Builds](https://reproducible-builds.org/)
- [SLSA Framework Specification (v1.2)](https://slsa.dev/spec/v1.2/)
- [Red Hat: Reproducible Container Builds](https://docs.redhat.com/en/documentation/red_hat_enterprise_linux/10/html/building_running_and_managing_containers/introduction-to-reproducible-container-builds)
- [TEP-0025: Hermekton — Hermetic Builds in Tekton](https://github.com/tektoncd/community/blob/main/teps/0025-hermekton.md)
- [Tekton Chains SLSA Provenance](https://github.com/tektoncd/chains/blob/main/docs/slsa-provenance.md)
- [Go Blog: Perfectly Reproducible Builds](https://go.dev/blog/rebuild)
- [SOURCE_DATE_EPOCH Spec](https://reproducible-builds.org/specs/source-date-epoch/)
- [arXiv:2602.17678 — Docker Reproducibility Study](https://arxiv.org/abs/2602.17678)
- [BuildKit Reproducible Builds](https://github.com/moby/buildkit/blob/master/docs/build-repro.md)
