# Amp self-hosted orbs on K3s

Run [Amp orbs](https://ampcode.com/docs/orbs/self-hosted) on your own small K3s cluster (2 to 10
machines), such as a homelab. This uses Amp's official
[orb-provider Helm chart](https://ampcode.com/docs/orbs/self-hosted/kubernetes) in `cloud=eks`
mode. A Helm post-renderer fits it to K3s. Amp does not support this setup.

How it works: one pod in the cluster connects out to ampcode.com and receives spawn, pause and
resume jobs. Each orb runs as a gVisor sandbox pod on one of your nodes. A paused orb's files and
memory are saved on its node and uploaded to an S3 gateway (Versity) running in the cluster, so it
can resume with its processes still running, on the same node in seconds or on any other node
from the gateway. No inbound ports are needed.

What the overlay changes in the chart:

- Postgres: 500 GiB PVC and 2 CPU request become 5 GiB and 250m.
- `ate-api-server` and `ate-idp-server`: 2 replicas become 1.
- Snapshots: go to an in-cluster [Versity S3 Gateway](https://github.com/versity/versitygw)
  instead of AWS. It stores each object as a plain file, so its data can live on a local disk or
  an NFS share on your NAS.
- atelet: the EKS image credential provider is removed, so the public images are pulled
  anonymously. Snapshot uploads get more time, and the local copy is kept for a day (see
  [Snapshot timing](#snapshot-timing)).
- Memory snapshots: the provider patches two settings in its own code at start, so a pause
  saves process memory too and returns before the upload (see
  [Memory snapshots](#memory-snapshots)).
- The `sandboxconfig-assets` admission policy is left to the chart's pre-install hook, which
  already applies it. Without this, Helm 3 fails a fresh install with "already exists".

Control-plane requests drop from 2.56 CPU / 3.2 GiB / 500 GiB to about 0.85 CPU / 2.8 GiB /
5 GiB, plus the snapshot data.

## 1. Create the provider in Amp

Do this first: the install needs the provider's token.

1. Open [Settings → Orbs](https://ampcode.com/settings/orbs) and click **Add Provider** for a
   provider only you can use. For one your whole workspace can use, a workspace admin clicks
   **Add Orb Provider** in the workspace's **Settings → Orbs** instead.
2. Name it, for example `homelab`. You pick the provider by this name when you start a thread.
3. Copy the `aop_live_…` token. It is shown once. Keep it somewhere safe until step 3.
4. Open the provider's **Edit** dialog and add these orb types under **Orb types**. Make `small`
   the default:

   | Type | CPU | Memory |
   | --- | --- | --- |
   | `tiny` | 1 | 2 GiB |
   | `small` | 2 | 4 GiB |
   | `medium` | 4 | 8 GiB |
   | `large` | 8 | 16 GiB |
   | `xxlarge` | 16 | 32 GiB |

   They have the same CPU and memory as the Amp-hosted `a1.*` sizes. The names must match
   `workers.types` in `values.yaml`. Amp cannot rename a type once it is saved, so if you change
   them, change both places.

## 2. Cluster

Use one K3s server and every other machine as an agent. The default SQLite datastore is enough.
Embedded etcd only helps once you have 3 servers.

Each node needs:

- Linux x86_64 with cgroup v2 and user namespaces. For ARM64, switch `workers.architecture` and
  the guest image; see the chart's `docs/self-hosted.md`.
- **Kernel 6.7+ or 6.6.23+**. Substrate mounts orb filesystems with overlayfs `lowerdir+`, so on
  older kernels every orb fails with "while creating overlay superblock: invalid argument".
  Debian 12's 6.1 is too old. Ubuntu 24.04's 6.8 and Debian 13's 6.12 are new enough.
- Outbound HTTPS to `ampcode.com`, `static.ampcode.com`, `tunnel.ampcode.com`, your Git host,
  `registry.npmjs.org`, `us-central1-docker.pkg.dev`, `registry-1.docker.io` and
  `storage.googleapis.com`.

```sh
# every node
git clone https://github.com/meln1k/amp-k3s-orb-provider && cd amp-k3s-orb-provider
sudo ./node-prep.sh
# server
curl -sfL https://get.k3s.io | sh -s - server --disable traefik --disable servicelb
# each agent (token: /var/lib/rancher/k3s/server/node-token on the server)
curl -sfL https://get.k3s.io | K3S_URL=https://<server>:6443 K3S_TOKEN=<token> sh -
```

Label every machine that should run orbs. Don't taint them: atelet only needs the label, and
leaving the taint off lets the small control plane share the same machines.

```sh
kubectl label node <node> ate.dev/sandboxClass=gvisor
```

## 3. Install

Run this as root on the K3s server, in the clone of this repo. Use Helm 3 (3.14 or newer): Helm 4
only accepts post-renderers packaged as plugins. From another machine, use the cluster's
kubeconfig instead of the K3s one.

```sh
# Helm 3, and the K3s kubeconfig for it (K3s's kubectl finds it on its own, Helm does not)
curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml

# S3 credentials for the snapshot gateway, used by kustomization.yaml; gitignored
(umask 077; printf 'AWS_ACCESS_KEY_ID=%s\nAWS_SECRET_ACCESS_KEY=%s\n' \
  "$(openssl rand -hex 10)" "$(openssl rand -hex 24)" > s3.env)

# the provider token from step 1, typed at a hidden prompt
kubectl create namespace amp-orbs
read -rsp 'Provider token: ' T; printf '\n'
kubectl -n amp-orbs create secret generic amp-orb-spawner --from-literal=AMP_ORB_PROVIDER_TOKEN="$T"; unset T

helm install orb-provider oci://us-central1-docker.pkg.dev/amp-prod-0/orb-provider/chart \
  --version 0.20261109.1946 -n amp-orbs -f values.yaml --post-renderer ./post-render.sh --wait --timeout 20m
```

Every pod should be ready within a few minutes. The first orb on a node also pulls the 7 GiB
orb image.

## 4. Start a thread

In the new thread composer, click **Orb**, open the type dropdown, and choose your provider
under **Self-Hosted**, then an orb type. From the CLI:

```sh
amp -ox "your first message" --orb-provider homelab --orb-size small
```

To use the provider for every new thread, choose it under **Default Orb** in Settings → Orbs.

To check that it works: start a background process in the thread, such as a dev server, and
create a file. Wait until Amp shows the orb paused, then send another message: the file is still
there and the process is still running, with the same PID.

## Performance

Measured on one Intel N150 mini PC with 16 GB RAM, with snapshots on a UniFi UNAS 2 over gigabit
NFSv3. Two `small` orbs each held 1 GiB of memory and a 200 MB file and were paused and resumed
together:

| | |
| --- | --- |
| Pause (snapshot written to the node's disk) | 3 to 5 s |
| Upload to the NAS, in the background | about 95 s for both, one at a time |
| Resume from the node's local copy | about 4 s |
| Resume from the NAS | 34 to 40 s, both downloading at gigabit line rate |
| Snapshot size | 1.6 GB on the node, 1.4 GB compressed on the NAS |

Resume times run from the cluster receiving the job until the orb is ready. Amp takes another
2 to 15 s to send the job. Processes, memory and files were intact after every resume.

On a 4-vCPU, 16 GB Hetzner machine, the idle cluster used about 1.9 GB of RAM, a spawn on a warm
`small` worker took 11 s, and the first orb on a node took about 60 s, because it pulls the
7 GiB orb image once.

## Sizing

Each running orb reserves `memoryGi + 1 GiB` on a node. For example, a 64 GiB machine fits about
six `medium` (8 GiB) orbs or eleven `small` (4 GiB) orbs next to the control plane. Each orb also
uses disk on its node: the 7 GiB orb image once per node, plus whatever the orb writes.

Paused orbs live in the `versitygw` pod's `/data`, one file per object. By default that is a
local-path volume under `/var/lib/rancher/k3s/storage` on whichever node runs the pod.

To keep them on a NAS, replace the `data` volume in `versitygw.yaml` with the commented `nfs`
volume, and install `nfs-common` on every node. The gateway needs write access to the export.

- **NFS 4.2** works as is: the gateway stores object metadata in extended attributes, which NFS
  supports from 4.2 on.
- **NFSv3**, which is what a UniFi UNAS serves, has no extended attributes, and the gateway
  refuses to start on it ("xattrs are not supported on this filesystem"). Uncomment
  `VGW_META_SIDECAR` and the `/meta` mount: metadata then goes in files under `meta/` next to
  `data/` on the same export. Versity calls this mode experimental. It passed the same S3 calls
  Substrate makes on an NFSv3 export with `all_squash`, as the UNAS sets up its shared drives.
- For a UNAS: enable NFS in UniFi Drive > Settings > Services, create a shared drive, and leave it
  in the default Collaborative (all squash) mode. Its export path is
  `/var/nfs/shared/<Shared_Drive_Name>`.
- On a UNAS 2 over gigabit, the shared drive was exported as NFSv3 only (4.2 was refused), and
  a `sync` export moved about 107 MB/s writing and 117 MB/s reading. Snapshot uploads reached
  only 25 to 30 MB/s each: a node uploads one snapshot at a time, and the gateway assembles each
  multipart upload by copying its parts into a new file, which over NFSv3 reads them back across
  the network (about 20 s for a 1.1 GB memory image). Downloads run in parallel at line rate.

### Snapshot timing

Each pause writes the snapshot to the node's disk first, then atelet uploads it to the gateway.
The overlay changes two atelet defaults for a homelab store:

- **Upload time limit:** atelet cancels and retries an upload after `--snapshot-upload-timeout`
  plus the snapshot's size at `--snapshot-upload-est-throughput-mib`. The defaults (2m, 100 MiB/s)
  cut off two 2 GB snapshots uploading together to a NAS; the overlay sets 3m and 20 MiB/s,
  about 5 minutes for a 2.3 GB snapshot.
- **Local copy:** atelet keeps the latest snapshot on the node for `--snapshot-detach-delay`
  (default 30m, here 24h). Until then a wake restores from that copy without touching the store,
  and the orb is pinned to that node; if the node is full, the orb moves to another node and
  restores from the store. Local copies are uncompressed, about 1 to 3 GB per paused `small`
  orb, and atelet does not delete them early when the disk fills, so lower the delay on nodes
  with little free disk.

## Memory snapshots

Amp's provider asks for file-only snapshots: a resumed orb keeps its files, but its processes
start again. Substrate's gVisor worker can also save process memory (`runsc checkpoint`), and
[`provider-patch.yaml`](provider-patch.yaml) turns that on. It also makes a pause return as soon
as the snapshot is on the node's disk, while the upload to the gateway continues in the
background, so a pause takes a few seconds instead of waiting for the upload.

The provider has no setting for either, so the patch replaces two exact strings in its code
when the container starts. It refuses to start if a string is not found exactly once, so a chart
that moves them fails loudly (the provider logs `k3s patch: found 0 times`) instead of silently
running without it. Then remove the patch from `kustomization.yaml` and upgrade: orbs fall back
to file-only snapshots.

Things to know:

- **Docker inside an orb:** containers that were running keep running across a pause, but the
  `docker0` bridge is gone after a restore. New containers on the default bridge network fail with
  "Device does not exist"; `--network host` works. Restarting dockerd brings the bridge back but
  stops the running containers.
- **Runtime changes:** a memory snapshot only restores on a worker with the same gVisor build and
  compatible CPU features. When none matches, such as after a chart upgrade that changes the
  gVisor worker, Substrate's code restores the orb's files without its memory, but an orb whose
  snapshot is still on its node first tries to move to a matching node. This has not been tested
  here: after such an upgrade, resume a test orb before relying on it.
- **Snapshot size:** a snapshot holds the memory the orb uses as well as its file changes. An orb
  holding 1 GiB came to 1.6 GB on the node and 1.4 GB compressed in the store. Size the node's
  disk for the local copies and the store for the uploads.
- The chart's default is file-only snapshots, so this path is less tested than the default.

## Troubleshoot

If an orb does not start, read the thread's setup log and the provider's logs:

```sh
kubectl -n amp-orbs logs deploy/amp-orb-provider -c provider
kubectl -n amp-orbs logs deploy/amp-orb-provider -c spawner
```

To replace the provider token in the cluster:

```sh
read -rsp 'Provider token: ' T; printf '\n'
kubectl -n amp-orbs create secret generic amp-orb-spawner --from-literal=AMP_ORB_PROVIDER_TOKEN="$T" \
  --dry-run=client -o yaml | kubectl apply -f -; unset T
kubectl -n amp-orbs rollout restart deployment/amp-orb-provider
```

## Upgrade

This overlay is checked against chart 0.20261109.1946, so the commands pin it. Pull the repo and
upgrade to the version it pins, with the same post-renderer every time:

```sh
helm upgrade orb-provider oci://us-central1-docker.pkg.dev/amp-prod-0/orb-provider/chart \
  --version 0.20261109.1946 -n amp-orbs --reset-then-reuse-values --post-renderer ./post-render.sh --wait --timeout 30m
```

If a new chart moves the atelet credential-provider args, the `test` ops fail the render instead
of silently installing something broken. If it moves the strings `provider-patch.yaml` replaces,
the provider fails to start; see [Memory snapshots](#memory-snapshots). Before upgrading, read
`changelog.md` in Amp's [install bundle](https://ampcode.com/docs/orbs/self-hosted/bundle.zip)
for releases that need a manual step.

## Uninstall

Delete the provider in Amp first. That revokes its token, and threads on it stop working. Then
remove the chart and what Helm leaves behind:

```sh
helm uninstall orb-provider -n amp-orbs
kubectl delete ns amp-orbs ate-system otel-system podcertificate-controller-system --ignore-not-found
kubectl delete crd actortemplates.ate.dev csidriverconfigs.ate.dev sandboxconfigs.ate.dev workerpools.ate.dev --ignore-not-found
kubectl delete clusterrole,clusterrolebinding amp-orb-provider-nodes ate-api-server ate-controller \
  atelet atenet-router podcert-ate-dev-signer substrate-bootstrap --ignore-not-found
kubectl delete validatingadmissionpolicy,validatingadmissionpolicybinding sandboxconfig-assets --ignore-not-found
kubectl delete role,rolebinding atenet-dns -n kube-system --ignore-not-found
```

Deleting `ate-system` also deletes the gateway. With the default local volume, that deletes
every paused orb; on an NFS share the files stay.
