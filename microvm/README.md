# MicroVM orbs (experimental prototype)

Runs orbs as Kata guests on Cloud Hypervisor instead of gVisor, with memory snapshots: processes
keep running across a pause, and a resume loads guest memory lazily (userfaultfd). Amp does not
support this, and it has not run a real orb yet.

What it adds on top of the base overlay:

- `sandboxconfig.yaml`: the `microvm` SandboxConfig, copied from Substrate's
  `manifests/ate-install/sandboxconfig-microvm.yaml.tmpl` at `dc2bfeae`, the commit Amp's chart
  0.20261109 runs. Kata 4.3.1 and Cloud Hypervisor v53.0, amd64 only.
- `stage-assets.yaml`: a Job that downloads the guest kernel, guest image, `virtiofsd` and
  `cloud-hypervisor` from their GitHub releases, checks their sha256, and uploads them to the
  S3 gateway where the SandboxConfig points.
- `provider-patch.yaml`: patches Amp's provider at start to create `microvm` worker pools,
  `MEMORY` snapshots and asynchronous uploads, and points `WORKER_IMAGE` at `ateworker-microvm`.

## The worker image

Amp publishes only `ateworker-gvisor`. Build `ateworker-microvm` from the same Substrate commit
with Go 1.27.3 and the repo's pinned ko (v0.19.1), then push it:

```sh
git clone https://github.com/agent-substrate/substrate && cd substrate
git checkout dc2bfeae63b43c65572400f65dcc98b974c290db
(cd hack/tools/ko && go build -o /usr/local/bin/ko github.com/google/ko)
KO_DOCKER_REPO=ghcr.io/<you>/substrate ko build ./cmd/ateworker-microvm -B \
  --platform=linux/amd64 --tags=dc2bfeae63b43c65572400f65dcc98b974c290db
```

Set the result in `provider-patch.yaml`. The image must be pullable by the nodes.

## Enable

1. Every orb node needs `/dev/kvm` (bare metal, or a VM with nested virtualization). atelet
   advertises it as `ate.dev/kvm`, and Substrate's controller adds that request to microVM
   workers itself. Check with
   `kubectl get nodes -o jsonpath='{range .items[*]}{.metadata.name} {.status.capacity.ate\.dev/kvm}{"\n"}{end}'`.
2. Label the nodes `ate.dev/sandboxClass=microvm` instead of `gvisor`.
3. In `kustomization.yaml`, add to `resources`:
   `microvm/sandboxconfig.yaml` and `microvm/stage-assets.yaml`, and to `patches`:

   ```yaml
   - target: {kind: Deployment, name: amp-orb-provider, namespace: amp-orbs}
     path: microvm/provider-patch.yaml
   ```

Do this on a fresh install. An orb keeps the sandbox class of its first snapshot, so threads
paused under gVisor cannot resume on microVM workers.
