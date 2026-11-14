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

- Postgres: a 5 GiB volume instead of 500 GiB; requests 250m CPU and 512 MiB instead of 2 CPU
  and 1 GiB; limits 2 CPU and 1 GiB instead of 16 CPU and 2 GiB. Its `podcert-agent` init
  container runs as root, because Postgres refuses a TLS key owned by another user.
- `ate-api-server` and `ate-idp-server`: 2 replicas become 1.
- Snapshots: go to an in-cluster [Versity S3 Gateway](https://github.com/versity/versitygw)
  instead of AWS. It stores each object as a file encrypted with gocryptfs, on a local volume or
  an NFS export on your NAS (see [Snapshot store](#snapshot-store) and
  [Snapshot encryption](#snapshot-encryption)).
- atelet: the EKS image credential provider is removed, so the public images are pulled
  anonymously. Snapshot uploads get more time, and the local copy is kept for a day (see
  [Snapshot timing](#snapshot-timing)).
- Memory snapshots: the provider patches two settings in its own code at start, so a pause
  saves process memory too and returns before the upload (see
  [Memory snapshots](#memory-snapshots)).
- Worker size: the same patch gives each orb's worker pod its memory plus 128 MiB instead of
  plus 1 GiB (see [Sizing](#sizing)).

The control plane requests about 1.7 CPU and 0.5 GiB of memory less than the chart's default,
for about 0.8 CPU and 2.2 GiB in total, and 5 GiB of disk plus the snapshot store instead of
500 GiB.

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

Run this as root on the K3s server, in the clone of this repo. Use Helm 3: Helm 4 only accepts
post-renderers packaged as plugins. From another machine, use the cluster's kubeconfig instead
of the K3s one. To keep paused orbs on a NAS, set up [`nas-patch.yaml`](#snapshot-store) first.

```sh
# Helm 3, and the K3s kubeconfig for it (K3s's kubectl finds it on its own, Helm does not)
curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml

# S3 credentials for the snapshot gateway, used by kustomization.yaml; gitignored
(umask 077; printf 'AWS_ACCESS_KEY_ID=%s\nAWS_SECRET_ACCESS_KEY=%s\n' \
  "$(openssl rand -hex 10)" "$(openssl rand -hex 24)" > s3.env)

# the key that encrypts paused orbs, also gitignored; keep a copy somewhere safe, because
# without it every paused orb in the snapshot store is lost
(umask 077; openssl rand -base64 32 > snapshots.key)

# the provider token from step 1, typed at a hidden prompt
kubectl create namespace amp-orbs
read -rsp 'Provider token: ' T; printf '\n'
kubectl -n amp-orbs create secret generic amp-orb-spawner --from-literal=AMP_ORB_PROVIDER_TOKEN="$T"; unset T

# install; the same command upgrades
helm upgrade --install orb-provider oci://us-central1-docker.pkg.dev/amp-prod-0/orb-provider/chart \
  --version 0.20261109.1946 -n amp-orbs -f values.yaml --post-renderer ./post-render.sh --wait --timeout 30m
```

Every pod should be ready within a few minutes.

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

The UNAS exported its shared drive as NFSv3 only (4.2 was refused) and moved about 107 MB/s
writing and 117 MB/s reading. Uploads reach only 25 to 30 MB/s each: a node uploads one snapshot
at a time, and the gateway assembles each multipart upload by copying its parts into a new file,
which over NFSv3 reads them back across the network (about 20 s for a 1.1 GB memory image).

On a 4-vCPU, 16 GB Hetzner machine, the idle cluster used about 1.9 GB of RAM, a spawn on a warm
`small` worker took 11 s, and the first orb on a node took about 60 s, because it pulls the orb
image.

## Sizing

Each running orb reserves `memoryGi` plus 128 MiB on a node, and a `small` orb requests 1 CPU.
For example, a 64 GiB machine with enough CPUs fits about seven `medium` (8 GiB) orbs or fourteen
`small` (4 GiB) orbs next to the control plane. Each orb also uses disk on its node: the 7 GiB
orb image once per node, plus whatever the orb writes.

The chart gives each worker pod 1 GiB on top of the orb's memory. The worker keeps only 64 MiB of
that for itself, kills an orb that stays over its own `memoryGi`, and limits a pause's page cache
to what the orb leaves unused, so the pod stays under its limit with any extra of at least 64 MiB.
The rest only lets a pause write faster. On the [Performance](#performance) machine at plus
128 MiB, `small` orbs holding over 3 GiB came within 44 MiB of the pod's limit while pausing, and
no pod reached it. An orb that goes over its own memory is killed at any extra, and Amp's
provider then deletes it with its snapshots, so give orbs a size with room to spare and see
[Running out of memory](#running-out-of-memory).

A paused orb's snapshot holds the memory it uses as well as its file changes. Each paused orb
keeps its latest snapshot on its node for a day (see [Snapshot timing](#snapshot-timing)) and
its two newest in the snapshot store: a pause deletes the snapshot before the previous one. On
the [Performance](#performance) test, an orb holding 1 GiB took about 2 × 1.4 GB in the store.

### Running out of memory

gVisor has no OOM killer, and Amp does nothing about memory in self-hosted orbs: it showed no
warning and stopped nothing with an orb at 88% of its memory. So one process that grows too far
takes the whole orb with it: the worker kills the sandbox, and the provider deletes the orb with
its snapshots. Uncommitted and unpushed work in it is lost.

[earlyoom](https://github.com/rfjakob/earlyoom) kills the largest process first, while 10% of
the orb's memory is still free. To run it in every orb, a workspace admin pastes this into
workspace settings → Orbs → Advanced → **Resume Script**. Amp runs it on each orb's first start
and after every wake; it installs earlyoom in the background, so it stays within the script's
10 s limit, and exits at once on orbs that aren't gVisor and in woken orbs, where earlyoom is
still running from the snapshot.

```bash
#!/usr/bin/env bash
set -u
case "$(uname -r)" in *gvisor*) ;; *) exit 0 ;; esac
pgrep -x earlyoom >/dev/null && exit 0
(
	command -v earlyoom >/dev/null ||
		sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -q earlyoom >/dev/null ||
		{ sudo apt-get update -q >/dev/null && sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -q earlyoom >/dev/null; }
	# Every oom_score is 0 under gVisor, so earlyoom picks the process with the most memory.
	# --avoid keeps Amp's own processes and Docker's daemons out of that choice.
	amp orb service start earlyoom --command "earlyoom -m 10 -r 3600 --avoid '^(orbd|amp|dockerd|containerd)$'"
) >>/home/user/.cache/amp/logs/earlyoom-setup.log 2>&1 &
```

On the [Performance](#performance) machine, earlyoom was running 4 s after a new `small` orb
started. It stopped a process growing 128 MiB/s when 353 MiB was free, and the orb's other
processes, Amp's agent included, kept running; the sandbox stayed 249 MiB under its limit. It did
the same after the orb was paused and woken. An orb is unprotected for those first seconds, and
earlyoom picks only by size, so a large build or test run can still be the one it stops.

### Snapshot store

Paused orbs live in the `versitygw` pod, one encrypted file per object, under `encrypted/` on its
volume. By default that is a local-path volume under `/var/lib/rancher/k3s/storage` on whichever
node runs the pod.

To keep them on a NAS instead, set the export's server and path in
[`nas-patch.yaml`](nas-patch.yaml), uncomment it in `kustomization.yaml`, and install `nfs-common`
on every node. The gateway needs write access to the export. Object metadata goes in files under
`meta/` next to `data/` inside the encrypted store, so NFSv3, which has no extended attributes,
works too; Versity calls this mode experimental. It passed the S3 calls Substrate makes on an NFSv3
export with `all_squash`, as the UNAS sets up its shared drives. On an existing install, switching
deletes the local volume and every paused orb in it.

For a UniFi UNAS: enable NFS in UniFi Drive > Settings > Services, create a shared drive, and
leave it in the default Collaborative (all squash) mode. Its export path is
`/var/nfs/shared/<Shared_Drive_Name>`.

### Snapshot encryption

A paused orb's snapshot holds its memory, which can include tokens and other secrets. The gateway
writes every object through [gocryptfs](https://nuetzlich.net/gocryptfs/), so its volume, and the
NFS traffic to a NAS, only carry file contents and names encrypted with AES-256-GCM. Substrate and
the S3 API see plain objects.

- **Key:** `snapshots.key` becomes the Secret `orb-snapshots-key`, which only the gateway mounts.
  gocryptfs keeps its master key in `encrypted/gocryptfs.conf`, encrypted with it. Without the key
  the store can't be read; keep a copy outside the cluster. A wrong key stops the gateway, and its
  log says `Password incorrect`.
- **Costs:** mounting gocryptfs (FUSE) makes the gateway's container privileged and root. Its init
  container downloads gocryptfs v2.7.0 from GitHub at every start and checks its SHA-256. On the
  [Performance](#performance) machine, an orb holding 1 GiB still uploaded in 65 s and woke from
  the NAS in 15.6 s, as fast as without encryption, and the store grew by 0.8%. While moving a
  snapshot the gateway used about 0.7 CPU and filled its memory limit, mostly with page cache the
  kernel frees; at 512 MiB it ran at the limit without being killed, so the limit is 1 GiB.
- **Not covered:** the local copy of each snapshot on its node, under `/var/lib/ate`; use disk
  encryption such as LUKS for that. Uploads from atelet to the gateway are plain HTTP inside the
  cluster: between machines they cross your LAN unencrypted, unless K3s runs with
  `--flannel-backend=wireguard-native`. K3s stores the key's Secret unencrypted in its datastore
  on the server unless it runs with `--secrets-encryption`.

An install from before encryption keeps its old store, unencrypted, in `data/` and `meta/` next to
`encrypted/`. The gateway no longer reads them, so paused orbs whose snapshot is only there lose
their state. Delete those two directories by hand.

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

The provider has no setting for either, so the patch replaces two exact strings in its code, plus a
third for the worker size, when the container starts. It refuses to start if a string is not found
exactly once, so a chart that moves them fails loudly (the provider logs `k3s patch: found 0
times`) instead of silently running without it. Then remove the patch from `kustomization.yaml` and
upgrade: orbs fall back to file-only snapshots. The chart's default is file-only, so memory
snapshots are less tested.

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

This overlay is checked against chart 0.20261109.1946, which the install command pins. To
upgrade, pull the repo and run the install command again. It applies `values.yaml` and the
overlay as they are in the repo.

Before moving to a new chart version, read `changelog.md` in Amp's
[install bundle](https://ampcode.com/docs/orbs/self-hosted/bundle.zip) for releases that need a
manual step. The render fails if the chart renames Postgres or the replica targets, or moves the
atelet arguments, mounts and init containers the overlay patches. It cannot catch a renamed
atelet, `ate-api-server` or `amp-orb-provider` workload: those patches would be skipped, and
snapshots would go to AWS or lose their memory. If the provider's patched strings move, the
provider fails to start; see [Memory snapshots](#memory-snapshots).

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
every paused orb; on an NFS share the files stay, readable only with `snapshots.key`.
