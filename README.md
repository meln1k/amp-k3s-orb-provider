# Amp orbs on K3s

Run [Amp orbs](https://ampcode.com/docs/orbs/self-hosted) on your own machines: a small K3s
cluster of 1 to 10 Linux servers, such as a homelab. Threads you start on this provider run in
gVisor sandboxes on your hardware. A paused orb keeps its memory, so its processes are still
running when you come back. Its snapshot is kept on the node for a day and in an encrypted store
on local disk or your NAS. The cluster only connects out to ampcode.com: Amp needs no inbound
ports. On a machine with a public IP, firewall everything but SSH from the internet, because K3s
listens on 6443 and 10250.

It uses Amp's official [orb-provider chart](https://ampcode.com/docs/orbs/self-hosted/kubernetes)
and shrinks it for small machines with a Helm post-renderer: a 5 GiB Postgres instead of 500 GiB,
and about 1.6 CPU and 2.4 GiB for the control plane. Amp does not support this setup.

By default it also installs an **apps platform**, a self-hosted take on Amp Boxes: agents in your
orbs build and deploy long-running apps, which you open at `https://<app>.<your domain>` from any
device on your tailnet. Install with `--orbs-only` to leave it out.

**To set it up, give an Amp thread the link to this repo and ask it to set it up on your
machines.** The rest of this README is the guide it follows. How everything works, what was
measured and why things are the way they are: [docs/reference.md](docs/reference.md).

## Setup guide for agents

Follow these steps in order. Ask the user only for what is listed under **Ask the user**, all
at once at the start. Never ask for a credential in chat: store it with `manage_amp` (topic
`secrets`, operation `set`, scope `personal`, without `generated_value`), which opens a masked
dialog. The value then reaches the user's orbs as an environment variable, after
`amp orb restart-processes` in an orb that is already running. Before asking, check `env` for a
variable that already holds it, under any name. Never print a credential's value.

On an `amp --no-tui` runner, threads get these secrets only when the runner runs with
`--amp-env` or the setting `"amp.runner.env.enabled": true`; it then passes every secret the user
has to every thread it serves. It reads them when it starts, so a secret stored afterwards reaches
threads only after the runner restarts: ask the user for every credential before that restart. If yours has neither, ask the user to enable it and restart the
runner, or to run `install.sh` (step 4) on the server in a terminal and type each credential at
its hidden prompt. In the second case, continue from step 5, reading the Cloudflare token from
`kubectl -n cert-manager get secret cloudflare-api-token` without printing it.

The commands below assume a root shell. With sudo instead, prefix them with `sudo`, use
`sudo k3s kubectl` for kubectl, and pass credentials to `install.sh` on standard input as over
SSH (step 4), with `sudo bash -c` in place of `ssh`.

### Ask the user

Even when the user's request already answers some of these, list every missing item in one
message before step 1, including the Tailscale policy and OAuth client.

1. **The machines**, and how to reach a root shell on each: SSH (host, user, and a private key
   the user puts in your workspace, or a key pair you generate whose public key the user adds to
   `/root/.ssh/authorized_keys`), or this thread already running on the server, as root or with
   sudo. Which machine is the K3s server (the one with the most memory). Which branch or tag of
   this repo to install, if not `main`.
2. **The orb provider.** Its name, such as `homelab`. Tell the user they will confirm creating
   it in a dialog, or, if that is refused (see step 3), create it themselves, and that they add
   its orb types in Settings (step 3).
3. **Orbs only, or with the apps platform.** For the apps platform also:
   - A domain for the apps, such as `apps.example.com`, in a zone on Cloudflare.
   - A Cloudflare API token with Zone → DNS → Edit and Zone → Zone → Read on that zone, stored as
     a personal secret such as `CLOUDFLARE_API_TOKEN`; pass it to `install.sh` as
     `CLOUDFLARE_API_TOKEN` whatever its name.
   - In the [tailnet policy](https://login.tailscale.com/admin/acls), `"tag:k8s-operator": []` and
     `"tag:k8s": ["tag:k8s-operator"]` under `tagOwners`, and a grant that lets the user reach
     the apps, such as
     `{"src": ["autogroup:member"], "dst": ["tag:k8s"], "ip": ["tcp:80", "tcp:443"]}`.
   - A Tailscale [OAuth client](https://login.tailscale.com/admin/settings/oauth) with the
     Devices Core and Auth Keys write scopes and the tag `tag:k8s-operator`, stored as
     `TS_OAUTH_CLIENT_ID` and `TS_OAUTH_CLIENT_SECRET`.
4. **Optional: a NAS** for paused orbs, as an NFS export (server and path) writable by root or
   squashed to a user who can write. Without one they stay on the server's disk.

### 1. Check the machines

Each machine needs Linux x86_64 with cgroup v2 and user namespaces, **kernel 6.7+ or 6.6.23+**
(Ubuntu 24.04 and Debian 13 work, Debian 12 does not), and outbound HTTPS. Plan on 16 GB of
memory or more: each running orb reserves its size plus 128 MiB. On every machine:

```sh
git clone -b <branch or tag, default main> https://github.com/meln1k/amp-k3s-orb-provider /root/amp-k3s-orb-provider
cd /root/amp-k3s-orb-provider && ./node-prep.sh server   # on the server
cd /root/amp-k3s-orb-provider && ./node-prep.sh          # on every other machine
```

`node-prep.sh` stops with a message if the kernel is too old.

### 2. Install K3s

Set `node-ip` to the IPv4 address each machine is reached at by the others: its LAN address at
home, its public address on a single cloud server. Without it, K3s exits when the network hands
out a new IPv6 prefix. Between machines, allow 6443/tcp, 8472/udp and 10250/tcp.

```sh
# server
curl -sfL https://get.k3s.io | sh -s - server --disable traefik --disable servicelb --node-ip <server IPv4>
# every other machine; the token is /var/lib/rancher/k3s/server/node-token on the server
curl -sfL https://get.k3s.io | K3S_URL=https://<server IPv4>:6443 K3S_TOKEN=<token> sh -s - --node-ip <its IPv4>
# on the server: let orbs run on every machine
kubectl label node --all ate.dev/sandboxClass=gvisor
```

Copy the node token between machines without printing it.

### 3. Create the orb provider in Amp

Create it with `manage_amp` (topic `orb_providers`, operation `create`, scope `personal`, the
name from the user); the user confirms in a dialog. The token is saved in this machine's Amp CLI
storage, `~/.local/share/amp/secrets.json`, under the key `orb-provider-token@<Amp URL>`, such as
`orb-provider-token@https://ampcode.com/`. There is one per Amp URL, so creating another provider
replaces the previous one's token on this machine: copy it right away. Copy it to the server as `/root/orb-provider-token` (mode 600) without
printing it, for example `jq -r '<that key>' … | ssh root@<server> 'umask 077; cat > /root/orb-provider-token'`.

In an Amp orb, `create` is refused ("executor cannot save a provider token"). Then ask the user
to click **Add Provider** in [Settings → Orbs](https://ampcode.com/settings/orbs), and store the
`aop_live_…` token it shows with the masked dialog as `ORB_PROVIDER_TOKEN`. Pass it to
`install.sh` from your environment as in step 4.

Then ask the user to open [Settings → Orbs](https://ampcode.com/settings/orbs), edit the
provider, and add these orb types with `small` as the default; their names must match
`workers.types` in [`values.yaml`](values.yaml):

| Type | CPU | Memory |
| --- | --- | --- |
| `tiny` | 1 | 2 GiB |
| `small` | 2 | 4 GiB |
| `medium` | 4 | 8 GiB |
| `large` | 8 | 16 GiB |
| `xxlarge` | 16 | 32 GiB |

Then check with `manage_amp` (topic `orb_providers`, operation `list`) that the provider's types
are exactly these five names, with `small` as the default, and ask the user to fix any that
differ: an orb of a misspelled type never starts. Amp cannot rename a type, so a fix is adding the
right one and removing the wrong one.

### 4. Install

With a NAS, first check the export (mount it, create a file as root, unmount), then set its
server and path in [`nas-patch.yaml`](nas-patch.yaml), uncomment
`- path: nas-patch.yaml` in [`kustomization.yaml`](kustomization.yaml), and install `nfs-common`
on every machine. Then, on the server, as root:

```sh
cd /root/amp-k3s-orb-provider
curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash   # Helm 3, not 4
ORB_PROVIDER_TOKEN=$(cat /root/orb-provider-token) ./install.sh --orbs-only   # or from your env
```

For the apps platform, drop `--orbs-only` and also pass `APPS_DOMAIN`, `CLOUDFLARE_API_TOKEN`,
`TS_OAUTH_CLIENT_ID` and `TS_OAUTH_CLIENT_SECRET`. Pass credentials from your environment over
SSH on standard input, not on the command line, for example
`printf 'export X=%q\n' "$X" … | ssh root@<server> 'set -a; . /dev/stdin; cd …; ./install.sh'`.

[`install.sh`](install.sh) creates `s3.env` and `snapshots.key`, makes a Secret of each
credential, installs Amp's chart pinned to the tested version, and, for the apps platform, applies
[`platform/`](platform) and waits for the wildcard certificate and Traefik's tailnet address.
It can run again; a second run is an upgrade. A first install takes 5 to 15 minutes.

`snapshots.key` encrypts every paused orb. **Tell the user to copy
`/root/amp-k3s-orb-provider/snapshots.key` somewhere safe**; without it the paused orbs are lost.

### 5. Apps platform: DNS and access

Skip this with `--orbs-only`.

1. Create the record `install.sh` printed, `*.<domain>  A  <100.x address>`, DNS only (not
   proxied), with the Cloudflare API: the zone's ID from `GET /zones?name=<zone>`, then
   `POST /zones/<zone ID>/dns_records` with
   `{"type": "A", "name": "*.<domain>", "content": "<100.x address>", "proxied": false}`. Send the
   token as a header read from standard input (`curl -H @-`), not on the command line. Check with
   `dig +short x.<domain>`.
2. Give the user's orbs access to the `apps` namespace. Their Kubernetes user is
   `amp:<Amp user ID>`, a `user_…` ID. In the user's own orb it is `$AMP_USER_ID`; on a runner
   or the user's machine, `.accounts[].userID` in `~/.local/share/amp/accounts.json`.

   ```sh
   kubectl -n apps create rolebinding amp-<name> --role=agent --user=amp:<Amp user ID>
   ```

3. Store `./platform/agent-kubeconfig.sh`'s output as the environment variable `APPS_KUBECONFIG`
   and the domain as `APPS_DOMAIN`, with `manage_amp` (topic `environment_variables`, operation
   `set`, scope `personal`). Neither holds a credential.
4. Tell the user to add [`skills/deploying-k3s-apps`](skills/deploying-k3s-apps/SKILL.md) to their
   skills, and that only threads on this provider can deploy: the cluster's API is reachable only
   from inside it.

### 6. Check and report

On the server, every pod in `amp-orbs` and `ate-system` should be Running, and
`kubectl -n amp-orbs logs deploy/amp-orb-provider -c spawner` should show `Orb provider started`.
For the apps platform, also check that every pod in `cert-manager`, `tailscale`, `traefik`,
`registry` and `buildkit` is Running, that `kubectl -n traefik get certificate wildcard` is Ready,
that `x.<domain>` resolves to Traefik's 100.x address, and that `curl https://x.<domain>` (from a
device on the tailnet) gets Traefik's 404 with a valid certificate. Tell the user:

- The provider's name, and that they pick it under **Orb → Self-Hosted** in the thread composer,
  or make it the default under **Default Orb** in Settings → Orbs.
- To test it: start a thread on it, run a background process, wait until the orb pauses, then
  send another message; the process is still running.
- What was installed, where `snapshots.key` is, and for the apps platform the app URL pattern,
  that the skill `skills/deploying-k3s-apps` goes in their skills, and that only threads on this
  provider can deploy apps.

If something fails, read [Troubleshoot](docs/reference.md#troubleshoot) and the section of
[docs/reference.md](docs/reference.md) for the part that failed before changing anything.

## More

- [docs/reference.md](docs/reference.md): what the overlay changes, sizing, memory snapshots, the
  snapshot store and its encryption, the apps platform, upgrades and uninstall.
- [`skills/deploying-k3s-apps`](skills/deploying-k3s-apps/SKILL.md): how agents deploy apps.
