# Amp orbs on K3s

Run [Amp orbs](https://ampcode.com/docs/orbs/self-hosted) on your own machines: a K3s cluster of
1 to 10 Linux servers, such as a homelab. Threads on this provider run in gVisor sandboxes on your
hardware. A paused orb keeps its memory, so its processes are still running when you come back;
its snapshot is encrypted and stored on local disk or your NAS. The cluster only connects out to
ampcode.com and needs no inbound ports.

It uses Amp's official [orb-provider chart](https://ampcode.com/docs/orbs/self-hosted/kubernetes),
shrunk for small machines by a Helm post-renderer: a 5 GiB Postgres instead of 500 GiB, and about
1.6 CPU and 2.4 GiB for the control plane. Amp does not support this setup.

By default it also installs an **apps platform**, a self-hosted take on Amp Boxes: agents in your
orbs deploy long-running apps, which you open at `https://<app>.<your domain>` on your tailnet.

**To set it up, give an Amp thread the link to this repo and ask it to set it up on your
machines.** The rest of this README is its guide. How it works and why:
[docs/reference.md](docs/reference.md).

## Setup guide for agents

Before step 1, ask the user in one message for every item under **Ask the user** that their
request leaves open.

**Credentials.** Look in `env` first; one may be there under another name. Otherwise have the
user store it with `manage_amp` (topic `secrets`, operation `set`, scope `personal`, no
`generated_value`), which opens a masked dialog, and run `amp orb restart-processes` to load it.
Never ask for a value in chat or print one. On an `amp --no-tui` runner, threads get secrets only
with `"amp.runner.env.enabled": true` in the runner user's Amp settings, and only the ones stored
before the runner started: collect every credential, then have the user restart the runner.
Without that setting, have the user run `install.sh` (step 4) in a terminal on the server, which
prompts for each credential, and continue from step 5 with the Cloudflare token from
`kubectl -n cert-manager get secret cloudflare-api-token`.

**Root.** The commands below run as root on the server. With sudo, prefix them with `sudo`, run
anything that `cd`s into or globs under `/root` inside `sudo bash -c '…'` (`/root` is mode 700,
so your own shell can neither enter it nor expand globs there), and use `sudo k3s kubectl`.

### Ask the user

1. **The machines**: which one is the K3s server (the one with the most memory), and how to get
   a root shell on each: this thread running on it, or SSH (host, user, and a key the user puts
   in your workspace or a public key of yours they add to `/root/.ssh/authorized_keys`). A branch
   or tag of this repo, if not `main`.
2. **The orb provider**: its name, such as `homelab`. The user confirms creating it in a dialog
   and adds its orb types in Settings (step 3). To reuse one they have, ask where its token is
   (such as `/root/orb-provider-token`) and that it is this provider's, not another one's; the
   test thread in step 6 confirms it. Check its orb types now as in step 3, so any fix goes in
   this message.
3. **Orbs only, or with the apps platform.** For the apps platform:
   - A domain for the apps, such as `apps.example.com`, in a zone on Cloudflare.
   - A Cloudflare API token with Zone → DNS → Edit and Zone → Zone → Read on that zone.
   - In the [tailnet policy](https://login.tailscale.com/admin/acls), `"tag:k8s-operator": []` and
     `"tag:k8s": ["tag:k8s-operator"]` under `tagOwners`, and a grant that lets the user reach
     the apps, such as
     `{"src": ["autogroup:member"], "dst": ["tag:k8s"], "ip": ["tcp:80", "tcp:443"]}`.
   - A Tailscale [OAuth client](https://login.tailscale.com/admin/settings/oauth) with the
     Devices Core and Auth Keys write scopes and the tag `tag:k8s-operator`, stored as
     `TS_OAUTH_CLIENT_ID` and `TS_OAUTH_CLIENT_SECRET`.
4. **Optional: a NAS** for paused orbs: an NFS export (server and path) writable by root or
   squashed to a user who can write. Without one, they stay on the server's disk.

### 1. Prepare the machines

Each machine needs Linux x86_64 with cgroup v2 and user namespaces, **kernel 6.7+ or 6.6.23+**
(Ubuntu 24.04 and Debian 13 work, Debian 12 does not), outbound HTTPS, and 16 GB of memory or
more (`free -g` shows 15): each running orb reserves its size plus 128 MiB. On a machine with a public IP, firewall
everything but SSH from the internet: K3s listens on 6443 and 10250.

```sh
git clone -b <branch or tag> https://github.com/meln1k/amp-k3s-orb-provider /root/amp-k3s-orb-provider
cd /root/amp-k3s-orb-provider && ./node-prep.sh server   # on the server
cd /root/amp-k3s-orb-provider && ./node-prep.sh          # on every other machine
```

### 2. Install K3s

`--node-ip` is the IPv4 address the other machines reach it at: its LAN address at home (on the default
route, `ip -4 route get 1.1.1.1`, not a virbr0, docker0 or tailscale0 address), its public one on
a single cloud server. Without it, K3s exits when the network hands out a new IPv6
prefix. Between machines, allow 6443/tcp, 8472/udp and 10250/tcp.

```sh
# server
curl -sfL https://get.k3s.io | sh -s - server --disable traefik --disable servicelb --node-ip <server IPv4>
# every other machine, with the server's /var/lib/rancher/k3s/server/node-token (copied without printing it)
curl -sfL https://get.k3s.io | K3S_URL=https://<server IPv4>:6443 K3S_TOKEN=<token> sh -s - --node-ip <its IPv4>
# server, once `kubectl get nodes` lists every machine as Ready: let orbs run on every machine
kubectl label node --all ate.dev/sandboxClass=gvisor
```

### 3. The orb provider

Create it with `manage_amp` (topic `orb_providers`, operation `create`, scope `personal`). The
token lands in `~/.local/share/amp/secrets.json` under `orb-provider-token@<Amp URL>`, such as
`orb-provider-token@https://ampcode.com/`. The next `create` overwrites it, so copy it right away,
without printing it, to `/root/orb-provider-token` (mode 600) on the server:
`jq -r '<that key>' … | ssh root@<server> 'umask 077; cat > /root/orb-provider-token'`. In an Amp
orb, `create` is refused: have the user click **Add Provider** in
[Settings → Orbs](https://ampcode.com/settings/orbs) and store its `aop_live_…` token as the
secret `ORB_PROVIDER_TOKEN`.

The user then edits the provider in [Settings → Orbs](https://ampcode.com/settings/orbs) and adds
these types, `small` the default, named as `workers.types` in [`values.yaml`](values.yaml):

| Type | CPU | Memory |
| --- | --- | --- |
| `tiny` | 1 | 2 GiB |
| `small` | 2 | 4 GiB |
| `medium` | 4 | 8 GiB |
| `large` | 8 | 16 GiB |
| `xxlarge` | 16 | 32 GiB |

Check with `manage_amp` (topic `orb_providers`, operation `list`) that the type names are exactly
these, with `small` the default (`list` shows no CPU or memory): an orb of a misspelled type never starts. Amp cannot rename a
type; the user adds the right one and removes the wrong one.

### 4. Install

With a NAS: install `nfs-common` on every machine, then on the server check that root can write
to the export (on a squashed export the file belongs to the anonymous user, which is fine):
`d=$(mktemp -d) && mount -t nfs <server>:<path> $d && touch $d/t && ls -ln $d/t && rm $d/t; umount $d; rmdir $d`. Set its server and path in [`nas-patch.yaml`](nas-patch.yaml) and uncomment
`- path: nas-patch.yaml` in [`kustomization.yaml`](kustomization.yaml).

On the server, install Helm 3 if `helm version --short` is not v3 (Helm 4 cannot run the
post-renderer): `curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash`.
Then run [`install.sh`](install.sh). It reads the provider token from `/root/orb-provider-token`
(or `ORB_PROVIDER_TOKEN`) and, for the apps platform, `APPS_DOMAIN`, `CLOUDFLARE_API_TOKEN`
(whatever the secret's own name), `TS_OAUTH_CLIENT_ID` and `TS_OAUTH_CLIENT_SECRET` from its
environment; for orbs alone, pass `--orbs-only` instead. ssh and sudo start a clean environment,
so pass the variables on standard input, never on the command line:

```sh
{ printf 'export APPS_DOMAIN=%q\n' '<domain>'
  printf 'export CLOUDFLARE_API_TOKEN=%q\n' "$<its variable>"
  printf 'export TS_OAUTH_CLIENT_ID=%q TS_OAUTH_CLIENT_SECRET=%q\n' "$TS_OAUTH_CLIENT_ID" "$TS_OAUTH_CLIENT_SECRET"
} | ssh root@<server> 'set -a; . /dev/stdin; /root/amp-k3s-orb-provider/install.sh'
# on the server itself: replace `ssh root@<server>` with `sudo bash -c` and keep the quoted command
```

A first install takes 5 to 15 minutes and prints nothing while Helm waits for pods (2 to 3
minutes) and while it waits for the wildcard certificate (a few minutes), so run it in the background and watch `kubectl get pods -A`. It is safe to run again; a
second run upgrades.

### 5. Apps platform: DNS and access

Skip this with `--orbs-only`.

1. **DNS.** Point `*.<domain>` at the 100.x address `install.sh` printed, DNS only (not proxied),
   with the Cloudflare API: the ID of the zone holding the domain (`example.com` for
   `apps.example.com`) from `GET /zones?name=<zone>`, then
   `GET /zones/<zone ID>/dns_records?name=*.<domain>`. A reinstall changes the address, so
   `PATCH /zones/<zone ID>/dns_records/<record ID>` an existing record, else
   `POST /zones/<zone ID>/dns_records`, with
   `{"type": "A", "name": "*.<domain>", "content": "<100.x address>", "proxied": false}`. Send the
   token on standard input, with `$TOKEN` the variable you passed as `CLOUDFLARE_API_TOKEN`:
   `printf 'Authorization: Bearer %s\n' "$TOKEN" | curl -H @- -H 'Content-Type: application/json' …`.
   Check with `dig +short x.<domain>`.
2. **Access.** The user's orbs act as the Kubernetes user `amp:<Amp user ID>`. The ID (`user_…`)
   is `$AMP_USER_ID` in the user's orb, or `.accounts[].userID` in
   `~/.local/share/amp/accounts.json` on a runner or the user's machine. The username, which only
   names the binding, is `ampUsername` from `get_current_user_identity` (module `amp`).

   ```sh
   kubectl -n apps create rolebinding amp-<Amp username> --role=agent --user=amp:<Amp user ID>
   ```

3. **Environment.** Store `./platform/agent-kubeconfig.sh`'s output, one line of JSON passed
   unchanged, as `APPS_KUBECONFIG` and the domain as `APPS_DOMAIN` with `manage_amp` (topic
   `environment_variables`, operation `set`, scope `personal`; neither is a credential), and read
   `APPS_KUBECONFIG` back with operation `get` to compare it with the script's output. Overwrite existing ones: a K3s reinstall changes the
   cluster's CA. Orbs load them after `amp orb restart-processes`, runner threads after the runner
   restarts.

### 6. Check and report

On the server, every pod in `amp-orbs` and `ate-system` is Running (with a NAS,
`kubectl -n ate-system get pvc` lists no `snapshots-data`), and
`kubectl -n amp-orbs logs deploy/amp-orb-provider -c spawner` shows `Orb provider started`. With
the apps platform, also every pod in `cert-manager`, `tailscale`, `traefik`, `registry` and
`buildkit` is Running, `kubectl -n traefik get certificate wildcard` is Ready, `x.<domain>`
resolves to Traefik's 100.x address, and `curl https://x.<domain>` from the tailnet gets Traefik's
404 with a valid certificate. Last, start a thread on the provider with `create_thread`
(`orb_provider` its name, `orb_size` `small`, `project` `no-project`) that runs `uname -a`. Its
first spawn takes about 1.5 minutes; when the spawner log shows `Orb spawned` for
`amp-<its thread ID without T->`, this cluster serves the provider.

If something fails, read [Troubleshoot](docs/reference.md#troubleshoot) and the section of
[docs/reference.md](docs/reference.md) for that part before changing anything.

Tell the user all of these:

- **Copy `/root/amp-k3s-orb-provider/snapshots.key` somewhere safe.** It encrypts every paused
  orb; without it they are lost.
- Pick the provider under **Orb → Self-Hosted** in the thread composer, or make it the default
  under **Default Orb** in Settings → Orbs. To test it, start a thread on it, run a background
  process, wait until the orb pauses, then send another message: the process is still running.
- With the apps platform: add [`skills/deploying-k3s-apps`](skills/deploying-k3s-apps/SKILL.md)
  to their skills. Apps are at `https://<app>.<domain>`, and only threads on this provider can
  deploy them, because the cluster's API is reachable only from inside it.
