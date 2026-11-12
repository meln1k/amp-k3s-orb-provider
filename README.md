# Amp self-hosted orbs on K3s

Amp's official orb-provider chart, installed in `cloud=eks` mode with a Helm post-renderer that
fits it to a small K3s cluster (2 to 10 machines). Amp does not support this setup.

What the overlay changes:

- Postgres: 500 GiB PVC and 2 CPU request become 5 GiB and 250m.
- `ate-api-server` and `ate-idp-server`: 2 replicas become 1.
- Snapshots: go to an in-cluster RustFS (S3) instead of AWS. These are the same settings
  Substrate uses for its kind profile.
- atelet: the EKS image credential provider is removed, so the public images are pulled
  anonymously.
- The `sandboxconfig-assets` admission policy is left to the chart's pre-install hook, which
  already applies it. Without this, Helm 3 fails a fresh install with "already exists".

Control-plane requests drop from 2.56 CPU / 3.2 GiB / 500 GiB to about 0.85 CPU / 2.8 GiB /
5 GiB, plus the RustFS data.

## 1. Cluster

Use one K3s server and every other machine as an agent. The default SQLite datastore is enough.
Embedded etcd only helps once you have 3 servers. Each node needs Linux with cgroup v2, user namespaces,
**kernel 6.7+ or 6.6.23+** (Substrate mounts orb filesystems with overlayfs `lowerdir+`; on older
kernels every orb fails with "while creating overlay superblock: invalid argument"; Debian 12's
6.1 is too old, Ubuntu 24.04's 6.8 and Debian 13's 6.12 are new enough), and x86_64 (or switch `workers.architecture` and the guest image, see
the chart's `self-hosted.md`).

```sh
# server
curl -sfL https://get.k3s.io | sh -s - server --disable traefik --disable servicelb
# each agent (token: /var/lib/rancher/k3s/server/node-token on the server)
curl -sfL https://get.k3s.io | K3S_URL=https://<server>:6443 K3S_TOKEN=<token> sh -
# every node
sudo ./node-prep.sh
```

Label every machine that should run orbs. Don't taint them: atelet only needs the label, and
leaving the taint off lets the small control plane share the same boxes.

```sh
kubectl label node <node> ate.dev/sandboxClass=gvisor
```

## 2. Install

```sh
(umask 077; printf 'AWS_ACCESS_KEY_ID=%s\nAWS_SECRET_ACCESS_KEY=%s\n' \
  "$(openssl rand -hex 10)" "$(openssl rand -hex 24)" > s3.env)
kubectl create namespace amp-orbs
read -rsp 'Provider token: ' T; printf '\n'
kubectl -n amp-orbs create secret generic amp-orb-spawner --from-literal=AMP_ORB_PROVIDER_TOKEN="$T"; unset T
helm install orb-provider oci://us-central1-docker.pkg.dev/amp-prod-0/orb-provider/chart \
  -n amp-orbs -f values.yaml --post-renderer ./post-render.sh --wait --timeout 20m
```

In Amp, add orb types `tiny`, `small`, `medium`, `large`, and `xxlarge` to the
provider (they must match `values.yaml`) and make `small` the default. They have the same
CPU and memory as the Amp-hosted `a1.*` sizes.

Use Helm 3: Helm 4 only accepts post-renderers packaged as plugins.

Upgrade with the same post-renderer every time:

```sh
helm upgrade orb-provider oci://us-central1-docker.pkg.dev/amp-prod-0/orb-provider/chart \
  -n amp-orbs --reset-then-reuse-values --post-renderer ./post-render.sh --wait --timeout 30m
```

If a new chart moves the atelet credential-provider args, the `test` ops fail the render instead
of silently installing something broken.

## Sizing

Each running orb reserves `memoryGi + 1 GiB` on a node. For example, a 64 GiB box fits about
six `medium` (8 GiB) orbs or eleven `small` (4 GiB) orbs next to the control plane. Each orb also uses disk on its node: the
7 GiB orb image once per node, plus whatever the orb writes. Paused orbs take 1 to 2 GiB each in
RustFS, under `/var/lib/rancher/k3s/storage` on the node running RustFS.
