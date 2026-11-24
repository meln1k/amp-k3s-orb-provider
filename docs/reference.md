# Reference

How the setup works, what it changes in Amp's chart and why, and what was measured. The
[README](../README.md) covers what this is and how to set it up.

## What the overlay changes

The repo is a NixOS module. At build time, [`orbs.nix`](../orbs.nix) pulls Amp's chart (pinned
by hash), renders it with `helm template`, and changes the result with Nix functions; the module
hands it to K3s as the auto-deploying manifest `amp-orbs`, which K3s applies on every start and
change. Each patch names the resource, container, volume or argument it changes, and the build fails when
a new chart renamed or removed it. Helm's pre-install hook, the `substrate-bootstrap` Job, becomes a
plain Job named after a hash of the hook resources, so a new chart runs a new one.
[`provider.nix`](../provider.nix) patches the provider's own code at build time, and the provider
container mounts the result from the server's Nix store. The root-only
`amp-orbs-secrets.service` creates the Secrets from files, so none enters the Nix store. It changes:

- Postgres: a 5 GiB volume instead of 500 GiB; requests 250m CPU and 512 MiB instead of 2 CPU
  and 1 GiB; limits 2 CPU and 1 GiB instead of 16 CPU and 2 GiB. Its `podcert-agent` init
  container runs as root, because Postgres refuses a TLS key owned by another user.
- `ate-api-server` and `ate-idp-server`: 2 replicas become 1.
- Snapshots: go to an in-cluster [Versity S3 Gateway](https://github.com/versity/versitygw)
  instead of AWS. It stores each object as a file encrypted with gocryptfs, on an NFS export on
  your NAS (see [Snapshot store](#snapshot-store) and
  [Snapshot encryption](#snapshot-encryption)).
- atelet: the EKS image credential provider is removed, so the public images are pulled
  anonymously. Snapshot uploads run one at a time with more time each, and the local copy is
  kept for a day (see [Snapshot timing](#snapshot-timing)).
- Memory snapshots: the build patches two settings in the provider's code, so a pause
  saves process memory too and returns before the upload (see
  [Memory snapshots](#memory-snapshots)).
- Worker size: the same patch gives each orb's worker pod its memory plus 128 MiB instead of
  plus 1 GiB, and has it request its whole CPU, its limit, instead of 1 CPU (see [Sizing](#sizing)).
- CPU under load: Substrate's containers that request no CPU get small requests (350m in total),
  the snapshot gateway requests 250m and atelet's objectstore plugin 100m, and the provider's
  probes get 10 s instead of 1 s, so busy orbs do not starve the control plane, stall snapshot
  uploads or get the provider restarted.
- Warm workers: one idle `small` worker, the default type, instead of one 16-CPU, 32 GiB
  worker, and no extra workers to fill a node's free room. On a 16-CPU server a spawn on it took
  about 10 s, and a cold one 22 s.
- earlyoom: the same patch starts earlyoom in every orb, so a runaway process is stopped
  before the orb runs out of memory (see [Running out of memory](#running-out-of-memory)).

With K3s's own pods, the control plane requests about 1.6 CPU and 2.4 GiB of memory, and 5 GiB
of disk plus the snapshot store instead of 500 GiB.

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

Each running orb reserves `memoryGi` plus 128 MiB on a node and requests its type's whole CPU,
which is also its limit. A node fits as many orbs as both allow, after 1 CPU the module reserves
for K3s and the host (`kubeReserved` and `systemReserved`, 500m each) and the control plane's
requests on the server: a 64 GiB machine with 12 cores fits about seven `medium` (8 GiB, 4 CPU)
orbs by memory but only two by CPU, and about four `small` (4 GiB, 2 CPU) orbs. Each orb also uses disk on its node: the 7 GiB orb image once per node, plus
whatever the orb writes.

Orbs request their whole CPU because they are rarely idle: compilers and browsers keep them
busy, and every orb slows down when a node admits more orb CPU than it has. Earlier versions
requested 750m. On the [Performance](#performance) machine (4 cores), 750m fit three `tiny`
orbs. Three orbs running a CPU and file-writing loop together left about a quarter of the CPU
idle. At 250m, six fit and kept the CPU saturated: their jobs ran 4 to 7 times slower, the
provider's probes timed out and the kubelet restarted it, spawns took up to 94 s, and orbs'
outbound connections timed out.

CPU sharing also decides how fast real work runs. On the same machine, three `tiny` orbs looping
`npm ci`, `tsc`, ESLint, tests and a `docker build` took 2.2 to 4.4 times as long per step as one
orb alone, and two took about 1.5 times as long. A `tiny` orb also sat at its 2 GiB limit during
builds, and earlyoom killed `tsc` once. For builds, use `small` and plan on about two busy orbs per
4 cores.

An orb holds its worker until it pauses, at least 5 minutes after its agent goes idle. A spawn
that finds no free worker waits about 9.5 minutes for one, then fails, and Amp retries it. So
when more orbs start at once than fit, expect some to fail once before they run. After orbs
pause, the provider waits 10 minutes before it shrinks the pool back to its warm worker, so
the idle workers keep their CPU and memory requests until then.

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

### Machine roles

Each machine has a `role` in the module:

- **server:** the control plane and the shared services, which are required to run here
  (`node-role.kubernetes.io/control-plane`): Postgres keeps its local volume on the node it first
  ran on, and the other machines may be off. It runs orbs too. In a wake of three orbs from the
  NAS the snapshot gateway used about 1 core; on a busy server, raise its CPU request in
  `orbs.nix` from 250m.
- **apps:** the apps platform and the apps; apps also run on the server. It has no
  `ate.dev/sandboxClass` label, so atelet does not run there, and a `NoSchedule` taint that orb workers do not tolerate, so no orb runs
  there. The platform's namespaces carry `PodNodeSelector` and `PodTolerationRestriction`
  annotations, which the API server adds to every pod in them: a selector for the machine's
  `amp-orbs/role=apps` label (`amp-orbs/runs-apps=true` in `apps`, which the server has too) and a
  toleration for its taint. An agent cannot move an app off these machines: a pod's own
  conflicting selector is refused.
- **burst:** orbs, when the others are full: a `PreferNoSchedule` taint makes the scheduler pick
  it last, though not strictly. Its shutdown waits up to 15 minutes: the kubelet's graceful
  shutdown stops the orb workers first, which suspend their orbs, then gives atelet, a critical
  pod, its 330 s to upload the snapshots to the NAS. Not tested yet: whether atelet finishes
  every upload in that time. A snapshot it did not upload stays only on the burst machine, and
  waking that orb elsewhere fails, which deletes it (see [Snapshot store](#snapshot-store)); boot
  the machine again before waking such an orb. It also runs tasks, short compute-heavy Jobs such
  as test sweeps (see [Tasks](#tasks)), and never apps: it has no `amp-orbs/runs-apps` label.

K3s adds a machine's labels again each time it starts, but its taints only when the node first
registers. To change a machine's role later, remove the old label and change its taints with
`kubectl label` and `kubectl taint` as well, or delete the node and restart K3s on it.

The module sets `nodeIP` on every node to its LAN IPv4 address. Otherwise K3s also records
the node's IPv6 address, and when the router hands out a new IPv6 prefix, K3s exits on its next
start ("NodeIPs changed for the node") before systemd restarts it.

On a server with 8 cores, 16 threads and 24 GB, memory runs out first: after the reservation and
the control plane, 4 `small` orbs fit, the warm worker counted as one, or 1 `small` and about 7
`tiny` (measured: 23868316Ki allocatable, 2412Mi requested before any orb). Those orbs can use at
most 8 or 9 threads between
them, so the shared services keep the rest even when every orb is busy.

### Running out of memory

gVisor has no OOM killer, and Amp does nothing about memory in self-hosted orbs: it showed no
warning and stopped nothing with an orb at 88% of its memory. Without help, one process that grows
too far takes the whole orb with it: the worker kills the sandbox, and the provider deletes the
orb with its snapshots, so uncommitted and unpushed work in it is lost.

So [`provider.nix`](../provider.nix) starts every new orb with a short shell wrapper
instead of Amp's `orbd` directly. The wrapper installs Debian's
[earlyoom](https://github.com/rfjakob/earlyoom) in the background, retrying until apt works,
runs it as `earlyoom -m 10 -r 3600 --avoid '^(orbd|amp|dockerd|containerd)$'` and restarts it if
it exits, then hands PID 1 to `orbd`. earlyoom stops the largest process while 10% of the orb's
memory is still free. Every `oom_score` is 0 under gVisor, so it picks by size alone, and
`--avoid` keeps Amp's own processes and Docker's daemons out of that choice. It logs to
`/var/log/earlyoom.log` in the orb. A woken orb keeps earlyoom running from its memory snapshot.

On the [Performance](#performance) machine, earlyoom was running 5 s after a new `small` orb
booted. It stopped a process growing 128 MiB/s when 350 MiB was free, and the orb's other
processes, Amp's agent included, kept running; in an earlier run the sandbox stayed 249 MiB under
its limit. It did the same after the orb was paused and woken. An orb is unprotected for those
first seconds, and because earlyoom picks only by size, a large build or test run can still be the
one it stops. Orbs created before the patch keep their old setup until they are recreated.

### Snapshot store

Paused orbs live in the `versitygw` pod on the server, one encrypted file per object, under
`encrypted/` on the NFS export `services.amp-orbs.nas` names. The gateway needs write access to
the export. Object metadata goes in files under
`meta/` next to `data/` inside the encrypted store, so NFSv3, which has no extended attributes,
works too; Versity calls this mode experimental. It passed the S3 calls Substrate makes on an NFSv3
export with `all_squash`, as the UNAS sets up its shared drives.

For a UniFi UNAS: enable NFS in UniFi Drive > Settings > Services, create a shared drive, and
leave it in the default Collaborative (all squash) mode. Its export path is
`/var/nfs/shared/<Shared_Drive_Name>`.

**Outages of the store can delete orbs.** When a wake has no local copy (see
[Snapshot timing](#snapshot-timing)), atelet downloads the snapshot from the gateway. If that
download fails, Substrate marks the orb crashed, and the provider deletes it together with every
snapshot it has in the store; Amp then gives the thread a new, empty orb. With the plugin's default
of 3 attempts, a 60 s gateway outage during two such wakes deleted both orbs. The overlay therefore
gives atelet's objectstore plugin 20 attempts (`AWS_MAX_ATTEMPTS`), and the same outage then only
delayed the wake by about 95 s. The NFS mount is `hard`, so while the NAS restarts, the gateway's
reads wait rather than fail; its liveness check only restarts it after 5 minutes of failures, so
that a NAS restart does not drop the downloads in flight. An outage that outlasts the retries can
still delete orbs that wake during it, so schedule NAS updates and restarts for when nobody uses
Amp. Wakes from a local copy do not read the store. A pause during an outage takes about 1.5
minutes longer and leaves the snapshot it replaces in the store until the orb is deleted.

### Snapshot encryption

A paused orb's snapshot holds its memory, which can include tokens and other secrets. The gateway
writes every object through [gocryptfs](https://nuetzlich.net/gocryptfs/), so its volume, and the
NFS traffic to a NAS, only carry file contents and names encrypted with AES-256-GCM. Substrate and
the S3 API see plain objects.

- **Key:** `/var/lib/amp-orbs/snapshots.key` on the server becomes the Secret `orb-snapshots-key`, which only the gateway mounts.
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
The overlay changes these atelet defaults for a homelab store:

- **Upload time limit:** atelet cancels and retries an upload after `--snapshot-upload-timeout`
  plus the data it holds in the upload buffer at `--snapshot-upload-est-throughput-mib`, and
  doubles the limit after each failure. The defaults (2m, 100 MiB/s) cut off two 2 GB snapshots
  uploading together to a NAS; the overlay sets 3m and 5 MiB/s, so a 416 MiB memory image gets
  about 4.4 minutes.
- **One upload at a time:** `--snapshot-upload-workers=1`. Uploads share the objectstore
  plugin's 512 MiB buffer, and an upload waiting there for room counts that wait against its
  limit. With three busy `tiny` orbs, two uploads failed three times each that way and finished
  57 minutes after their pause. With one worker, the next upload waits in atelet's queue instead.
  The gateway also requests 250m CPU: at 50m on a busy node it took up to 7 minutes to assemble
  one memory image. With both changes, three orbs paused together on a busy node uploaded one
  after another in 19, 22 and 52 s, each on its first try.
- **Local copy:** atelet keeps the latest snapshot on the node for `--snapshot-detach-delay`
  (default 30m, here 24h). Until then a wake restores from that copy without touching the store,
  and the orb is pinned to that node; if the node is full, the orb moves to another node and
  restores from the store. Local copies are uncompressed, about 1 to 3 GB per paused `small`
  orb, and atelet does not delete them early when the disk fills, so lower the delay on nodes
  with little free disk.

## Memory snapshots

Amp's provider asks for file-only snapshots: a resumed orb keeps its files, but its processes
start again. Substrate's gVisor worker can also save process memory (`runsc checkpoint`), and
[`provider.nix`](../provider.nix) turns that on. It also makes a pause return as soon
as the snapshot is on the node's disk, while the upload to the gateway continues in the
background, so a pause takes a few seconds instead of waiting for the upload.

The provider has no setting for either, so the build replaces two exact strings in its `main.js`,
plus two for the worker's memory and CPU and one for earlyoom. The build fails unless each string
occurs exactly once (`the provider has 0 occurrences of …`), so a chart that moves them cannot
silently run without them. To run without the patches, remove the `provider-main` volume and mount
from the `amp-orb-provider` patch in `orbs.nix` and deploy: new orbs take file-only snapshots and
run without earlyoom.
The chart's default is file-only, so memory snapshots are less tested.

To use file-only snapshots and keep the other patches, delete the `SNAPSHOT_FIDELITY_MEMORY` entry
from the list in `provider.nix` and deploy. The provider writes the setting into the
template each orb is created from, and a wake does not read the template again, so an orb keeps
the kind of snapshot it was created with for life: switching affects only orbs created afterwards.

On the [Performance](#performance) machine, `tiny` orbs woken one at a time, in seconds from the
thread being unarchived to the agent's first command in the orb (median of 3 wakes from the
node's copy and 2 from the NAS), and the size of each snapshot in the store:

| Orb | Memory: node's copy / NAS | File-only: node's copy / NAS | Store, memory / file-only |
| --- | --- | --- | --- |
| A repository after `npm ci`, with a running server | 12.6 / 14.8 s | 33.4 / 38.5 s | 169 / 116 MB |
| 768 MiB of random data in memory and 200 MB of random files | 14.9 / 30.8 s | 34.2 / 35.8 s | 1271 / 285 MB |

A memory wake restored the processes, so the server answered and the agent's connection carried on.
A file-only wake booted the orb again with only its files, and Amp then set up its connection anew,
which took about 20 s more before the agent could run a command. File-only pauses took about 1.3 s
instead of 2 to 4.5 s, and their uploads 6 to 12 s instead of 9 to 59 s.

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
- **Leftover cgroups:** each file-only pause leaves a few empty cgroups for the orb on its
  worker's node. They hold no processes and are removed slowly.

## Apps platform

The same cluster hosts long-running apps next to the orbs, like self-hosted Amp Boxes. An agent
builds an app's image in the cluster, deploys it, and you open it at
`https://<app>.apps.example.com` from any device on your tailnet. It lives in
[`platform/`](../platform). The module always installs it with the orbs
(see the README); the orbs neither use nor need it.

- **Traefik** ([`traefik.yaml`](../platform/traefik.yaml)) is the single entry point. Each app is a
  Deployment, a Service and an Ingress with its own hostname, served with one wildcard
  certificate; HTTP redirects to HTTPS.
- **Tailscale** ([`tailscale.yaml`](../platform/tailscale.yaml)): the
  [Kubernetes operator](https://tailscale.com/kb/1236/kubernetes-operator) exposes only Traefik's
  Service, so the cluster is one tailnet device, `k3s-apps`, however many apps it hosts. Traefik
  gets no node ports, so nothing listens on your LAN.
- **TLS** ([`cert-manager.yaml`](../platform/cert-manager.yaml), [`certs/`](../platform/certs)): a
  Let's Encrypt wildcard certificate over DNS-01, so nothing has to be reachable from the
  internet.
- **DNS** ([`coredns-custom.yaml`](../platform/coredns-custom.yaml)): inside the cluster, the apps'
  names resolve to Traefik's ClusterIP, so orbs and apps reach `https://crm.apps.example.com` too.
- **Isolation** ([`apps.yaml`](../platform/apps.yaml)): apps run in the namespace `apps`, with a
  quota, default container sizes and Pod Security `restricted` (non-root, no added capabilities,
  no host access). They accept connections only from Traefik and each other, and reach only each
  other, the cluster's DNS and the internet: not the LAN, the NAS, the nodes or other namespaces.
  Admission refuses LoadBalancer and NodePort Services, `externalIPs` and Tailscale annotations
  there, so every app goes through Traefik.
- **Agent access** ([`amp-auth.yaml`](../platform/amp-auth.yaml)): orbs sign in to the K3s API with
  Amp's workload identity, a 10-minute token `amp orb id-token` mints for each command, so no
  credential is stored anywhere. The API sees the thread's creator as `amp:<Amp user ID>`, and a
  RoleBinding per user gives the Role `agent` in `apps`, and one in `tasks` (see [Tasks](#tasks)):
  nothing in `amp-orbs`, `ate-system` or the nodes.
- **Images** ([`registry.yaml`](../platform/registry.yaml)): an in-cluster registry. Docker inside
  a gVisor orb cannot build, so agents build each app's image with Nix in their orb
  (`dockerTools`, from the app's `flake.nix`) and push it with `skopeo` over plain HTTP. Apps need
  a `flake.nix`; a Dockerfile alone cannot be built. The registry has no login: orbs reach it,
  and apps and tasks do not. Any orb could replace a tag, so the skill deploys the digest it
  pushed.
- **Agents' instructions**: the skill
  [`deploying-k3s-apps`](../skills/deploying-k3s-apps/SKILL.md) covers setup in an orb, build, push,
  deploy and its checks, Secrets the user types in themselves, roll back with `kubectl rollout
  undo`, and removal. It deploys only when the user asks.

Together the platform requests about 0.1 CPU and 320 MiB, plus the Tailscale proxy. Charts are
pinned (Traefik 42.4.0, cert-manager v1.21.3, Tailscale operator 1.104.7)
and installed by K3s's own Helm controller, so no Helm is needed for them.

### What orbs can reach

Checked from an orb on the [Performance](#performance) machine. An orb's connections leave
through the egress gateway, which resolves names with the cluster's DNS:

- **The K3s API** at `https://kubernetes.default.svc.cluster.local`: reachable, with K3s's own
  certificate. Orbs get no ServiceAccount token, and an anonymous request gets 401, so only a
  token the API accepts gets in.
- **Services**: TLS to any port by hostname (`metrics-server.kube-system.svc` answered 403), and
  cleartext HTTP on ports 80, 8080, 8000 and 3000 only, which is why the registry listens on
  8080.
- **Apps**: through Traefik only. NetworkPolicies see the egress gateway's pod in `ate-system` as
  the source, not the orb, and the policy in `apps` admits only Traefik and other apps.
- The chart's `ate-system-observability` policy admits every pod to metrics ports, so orbs can
  read `ate-system` metrics over HTTP on 8080 (`ate-controller` answered). This overlay does not
  change that.

### Apps and orbs

Apps run on the apps machine and the server, wherever the scheduler finds room; orbs never run
on the apps machine (see [Machine roles](#machine-roles)). The `apps` namespace selects nodes
labelled `amp-orbs/runs-apps=true`, which the module sets on both. The rest of the platform
(Traefik, the registry, cert-manager, the Tailscale operator) stays on the apps
machine. On the server, an app's memory request comes out of what orbs can reserve. Unlike
orbs, apps mostly idle, so they are overprovisioned on CPU: an app container that sets nothing
requests 50m and has no CPU limit, so it uses whatever CPU its machine has free, and its
memory limit equals its 128 MiB request. The quota in `apps.yaml` caps all apps together at
3 CPU and 6 GiB of requests and 8 GiB of limits; raise it to what the apps machine holds.

### Tasks

Short, compute-heavy work, such as a test or simulation sweep, runs as Jobs in the namespace
`tasks` ([`tasks.yaml`](../platform/tasks.yaml)), on the burst machines only. The namespace
selects nodes labelled `amp-orbs/role=burst`, which only burst machines have, and an agent cannot
move a task elsewhere: a conflicting selector is refused, and any other is added to it. Apps stay
off the burst machines the same way, since those lack `amp-orbs/runs-apps=true`. While every
burst machine is off, tasks wait Pending.

The rest matches `apps`, without the serving: Pod Security `restricted`; a quota (64 CPU, 96 GiB
of requests); containers that set nothing get 1 CPU and 1 GiB, with no CPU limit; tasks reach
each other, Traefik, the cluster's DNS and the internet. The Role `agent` there covers Pods, Jobs,
ConfigMaps and Secrets, and no Services, Ingresses or volumes. Images come from the same registry;
every node pulls from it.

Tasks share the burst machines with orbs. Orbs request their whole CPU, so tasks without a CPU
limit use only what orbs leave free, and the quota keeps room for orbs that overflow from the
server. A burst machine's shutdown gives its tasks up to 9.5 minutes to stop (the 15 minutes less
atelet's 330 s); a Job then runs that pod again on another burst machine, from the start, once
one is up. Not tested yet on a burst machine.

The registry keeps every image pushed. To free its disk, delete old tags and run, while nobody
pushes, `kubectl -n registry exec deploy/registry -- registry garbage-collect --delete-untagged
/etc/distribution/config.yml`.

### kubectl over Tailscale

Set `apiServerProxyConfig.mode` to `"true"` in `platform/tailscale.yaml` (in your fork or branch of this repo), deploy, and grant
yourself access in the tailnet policy. This maps tailnet admins to cluster admins:

```json
"grants": [{
  "src": ["autogroup:admin"],
  "dst": ["tag:k8s-operator"],
  "ip": ["tcp:443"],
  "app": {"tailscale.com/cap/kubernetes": [{"impersonate": {"groups": ["system:masters"]}}]}
}]
```

Then `tailscale configure kubeconfig k3s-operator` on your machine. For narrower access,
impersonate a group of your own and bind it with a RoleBinding, such as `edit` in `apps`. Not
tested yet.

## Troubleshoot

If an orb does not start, read the thread's setup log and the provider's logs:

```sh
kubectl -n amp-orbs logs deploy/amp-orb-provider -c provider
kubectl -n amp-orbs logs deploy/amp-orb-provider -c spawner
```

If the wildcard certificate stays pending and `kubectl -n traefik describe order` shows
`429 rateLimited`, Let's Encrypt has already issued 5 certificates this week for the same names,
which happens after several reinstalls on one domain. Wait until the retry time it gives, or
issue the wildcard alone, a different set of names with its own limit:

```sh
kubectl -n traefik patch certificate wildcard --type=merge -p '{"spec":{"dnsNames":["*.<domain>"]}}'
```

K3s restores both names when it next applies the manifests (on a restart or a deploy that changes
them), so do either only after the retry time.

To replace the provider token, write the new one to `/var/lib/amp-orbs/orb-provider-token`, then:

```sh
systemctl restart amp-orbs-secrets
kubectl -n amp-orbs rollout restart deployment/amp-orb-provider
```

If the manifests do not seem applied, `kubectl -n kube-system get addon` lists each one K3s
applied, and `kubectl -n kube-system describe addon amp-orbs` and `journalctl -u k3s` show why one
failed. The bootstrap Job's log is `kubectl -n amp-orbs logs job/substrate-bootstrap-<hash>`.

## Upgrade

This overlay is checked against chart 0.20261109.1946, which `orbs.nix` pins by version and hash.
To upgrade, update the flake input (`nix flake update amp-k3s`) and deploy. To try a new chart,
run `./update-chart.sh` (or `./update-chart.sh <version>`): it moves `orbs.nix` to the newest
chart, refills the chart's and the provider `main.js`'s hashes, and renders the manifest, which
fails if a patch no longer applies. Then check that the provider's patches still mean what they
did, and test on a cluster before committing.

K3s deletes the resources a new version leaves out of a manifest, as Helm did, but not those of a
manifest file that is removed. So removing a namespace from `orbs.nix` deletes it and everything
in it, including the snapshot gateway and Postgres.

Before moving to a new chart version, read `changelog.md` in Amp's
[install bundle](https://ampcode.com/docs/orbs/self-hosted/bundle.zip) for releases that need a
manual step. The build fails if the chart renames or removes any workload, container, volume or
argument the overlay patches, or if any string the provider's patches replace no longer occurs
exactly once; see [Memory snapshots](#memory-snapshots).

## Uninstall

Delete the provider in Amp first. That revokes its token, and threads on it stop working. Then
remove `services.amp-orbs` from the machines' configuration and deploy, which stops K3s. To
clean up a cluster you keep running for other things, delete what K3s leaves behind:

```sh
kubectl delete ns amp-orbs ate-system otel-system podcertificate-controller-system --ignore-not-found
kubectl delete crd actortemplates.ate.dev csidriverconfigs.ate.dev sandboxconfigs.ate.dev workerpools.ate.dev --ignore-not-found
kubectl delete clusterrole,clusterrolebinding amp-orb-provider-nodes ate-api-server ate-controller \
  atelet atenet-router podcert-ate-dev-signer substrate-bootstrap --ignore-not-found
kubectl delete validatingadmissionpolicy,validatingadmissionpolicybinding sandboxconfig-assets --ignore-not-found
kubectl delete role,rolebinding atenet-dns -n kube-system --ignore-not-found
```

Deleting `ate-system` also deletes the gateway. The files on the NAS stay, readable only with
`snapshots.key`. Removing K3s entirely also leaves `/var/lib/rancher`,
`/var/lib/ate` and `/var/lib/amp-orbs`.
