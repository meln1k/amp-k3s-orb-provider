# Amp self-hosted orbs on K3s

Run [Amp orbs](https://ampcode.com/docs/orbs/self-hosted) on your own small K3s cluster (2 to 10
machines), such as a homelab. This uses Amp's official
[orb-provider Helm chart](https://ampcode.com/docs/orbs/self-hosted/kubernetes) in `cloud=eks`
mode. A Helm post-renderer fits it to K3s. Amp does not support this setup.

How it works: one pod in the cluster connects out to ampcode.com and receives spawn, pause and
resume jobs. Each orb runs as a gVisor sandbox pod on one of your nodes. A paused orb's files
are saved to an S3 gateway (Versity) running in the cluster, so it can resume on any node. No
inbound ports are needed.

What the overlay changes in the chart:

- Postgres: 500 GiB PVC and 2 CPU request become 5 GiB and 250m.
- `ate-api-server` and `ate-idp-server`: 2 replicas become 1.
- Snapshots: go to an in-cluster [Versity S3 Gateway](https://github.com/versity/versitygw)
  instead of AWS. It stores each object as a plain file, so its data can live on a local disk or
  an NFS share on your NAS.
- atelet: the EKS image credential provider is removed, so the public images are pulled
  anonymously.
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
  -n amp-orbs -f values.yaml --post-renderer ./post-render.sh --wait --timeout 20m
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

To check that it works: run a command in the thread, wait until Amp shows the orb paused, then
send another message and check that a file you created is still there. Pauses save files only,
not memory, so processes such as dev servers start again after a resume.

## Performance

Measured on one 4-vCPU, 16 GB Hetzner machine (Ubuntu 24.04, K3s v1.37.2):

| | |
| --- | --- |
| Idle cluster RAM | about 1.9 GB |
| Spawn on a warm `small` worker | 11 s |
| First orb on a node (pulls the orb image once) | about 60 s |
| Pause | 17 to 25 s |
| Resume | 14 to 17 s |

Pause and resume time grows with what the orb writes. Each pause saves the orb's whole
filesystem diff, zstd-compressed (about 8 s), and uploads it (about 10 s for 1.3 GiB).
A repo whose `.agents/setup` installs system packages and `node_modules` came to 1.3 to 1.5 GiB
per paused orb. Project snapshots are stored the same way. A resume on the node that paused the
orb restores from a local copy in about 4 s; the rest is the orb reconnecting to Amp. A resume on
another node downloads the snapshot first.

These numbers were measured with RustFS on a local disk, before the switch to Versity.

## Sizing

Each running orb reserves `memoryGi + 1 GiB` on a node. For example, a 64 GiB machine fits about
six `medium` (8 GiB) orbs or eleven `small` (4 GiB) orbs next to the control plane. Each orb also
uses disk on its node: the 7 GiB orb image once per node, plus whatever the orb writes.

Paused orbs live in the `versitygw` pod's `/data`, one file per object. By default that is a
local-path volume under `/var/lib/rancher/k3s/storage` on whichever node runs the pod.

To keep them on a NAS, replace the `data` volume in `versitygw.yaml` with the commented `nfs`
volume, and install `nfs-common` on every node. The export must be writable by uid 1000.

- **NFS 4.2** works as is: the gateway stores object metadata in extended attributes, which NFS
  supports from 4.2 on.
- **Older NFS or SMB** have no extended attributes. Set `VGW_META_SIDECAR` and mount a second
  volume at `/meta`, as the comment in `versitygw.yaml` shows. Versity calls this mode
  experimental.
- Every pause uploads the whole snapshot, so the link to the NAS sets your pause time: gigabit
  moves about 110 MB/s, or about 12 s for a 1.3 GiB snapshot.

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

Run the upgrade with the same post-renderer every time:

```sh
helm upgrade orb-provider oci://us-central1-docker.pkg.dev/amp-prod-0/orb-provider/chart \
  -n amp-orbs --reset-then-reuse-values --post-renderer ./post-render.sh --wait --timeout 30m
```

If a new chart moves the atelet credential-provider args, the `test` ops fail the render instead
of silently installing something broken. Before upgrading, read `changelog.md` in Amp's
[install bundle](https://ampcode.com/docs/orbs/self-hosted/bundle.zip) for releases that need a
manual step.

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
