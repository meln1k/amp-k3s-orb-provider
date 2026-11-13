# MicroVM orbs (experimental prototype)

Runs orbs as Kata guests on Cloud Hypervisor instead of gVisor, with memory snapshots: processes
keep running across a pause. Amp does not support this.

Tested on one bare-metal node (Intel N150, 4 cores, 15 GiB, Ubuntu 24.04, kernel 6.8) with a
`small` orb on chart 0.20261109.1946:

| | |
| --- | --- |
| First orb on a node | 99 s, of which 88 s is pulling the orb image; the VM boots in 0.55 s |
| Pause | 0.9 to 2.5 s; the upload to the S3 gateway continues in the background (4 to 10 s) |
| Wake, from message to the orb running again | 1.75 s after a 2-minute pause |
| Memory restore | 0.47 to 0.53 s, also on a different worker |
| Snapshot of a small repo | 228 MB (154 MB memory, 74 MB files) |

A process started before the pause kept its PID and the guest kept its boot ID. A new thread
started from the project snapshot connected normally.

Known limitation: Docker inside the orb does not start (`while mounting cgroups: cpu: invalid
argument`). The guest kernel boots with `cgroup_no_v1=all` from Kata's defaults, and the orb's
Docker setup mounts cgroup v1.

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
with Go 1.27.3 and the repo's pinned ko (v0.19.1):

```sh
git clone https://github.com/agent-substrate/substrate && cd substrate
git checkout dc2bfeae63b43c65572400f65dcc98b974c290db
(cd hack/tools/ko && go build -o /usr/local/bin/ko github.com/google/ko)
KO_DOCKER_REPO=ghcr.io/<you>/substrate ko build ./cmd/ateworker-microvm -B \
  --platform=linux/amd64 --tags=dc2bfeae63b43c65572400f65dcc98b974c290db
```

The provider only accepts a digest-pinned `WORKER_IMAGE`, so put `<repo>@sha256:<digest>` in
`provider-patch.yaml`. Either:

- **Push it** (drop `--push=false`) to a registry every node can pull from, and use the digest
  ko prints.
- **Import it on every node** without a registry: build with `--push=false
  --tarball=ateworker-microvm.tar`, then on each node
  `sudo k3s ctr -n k8s.io images import ateworker-microvm.tar`, read the digest with
  `sudo k3s ctr -n k8s.io images ls | grep ateworker-microvm`, and add the digest reference
  `sudo k3s ctr -n k8s.io images tag <repo>:<tag> <repo>@sha256:<digest>`. Without that reference
  the kubelet tries to pull from the registry. A rebuilt node needs this again.

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
