# Amp orbs on K3s

Run [Amp orbs](https://ampcode.com/docs/orbs/self-hosted) on your own NixOS machines: a K3s
cluster of one server, one apps machine and any number of burst machines, such as a homelab.
The apps platform runs only on the apps machine, so a cluster without one never serves apps. Threads on this provider run in gVisor sandboxes
on your hardware. A paused orb keeps its memory, so its processes are still running when you
come back; its snapshot is stored, encrypted, on your NAS. The cluster only
connects out to ampcode.com and needs no inbound ports.

It is a NixOS module. It runs K3s, renders Amp's official
[orb-provider chart](https://ampcode.com/docs/orbs/self-hosted/kubernetes) at build time, shrinks
it for small machines (a 5 GiB Postgres instead of 500 GiB, and about 1.6 CPU and 2.4 GiB for the
control plane), and hands the result to K3s, so `nixos-rebuild switch` installs and upgrades the
whole cluster. Amp does not support this setup.

It also installs an **apps platform**, a self-hosted take on Amp Boxes: agents in your orbs
deploy long-running apps, which you open at `https://<app>.<your domain>` on your tailnet.

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
Without that setting, have the user write the files of step 2 themselves.

**Root.** The commands below run as root on the server. With sudo, prefix them with `sudo`, and
use `sudo k3s kubectl`.

### Ask the user

1. **The machines** and the role of each: one `server` (the control plane, the shared services
   and orbs), one `apps` machine (the apps platform and the apps, never orbs), and any number of
   `burst` machines (orbs when the others are full, and compute tasks; they may be shut down). And how to get a root
   shell on each: this thread running on it, or SSH (host, user, and a key the user puts
   in your workspace or a public key of yours they add to `/root/.ssh/authorized_keys`).
2. **Their NixOS configuration**: the flake that builds each machine, where it lives, and how
   changes reach the machines (`nixos-rebuild switch` on each, a deploy tool, or
   `system.autoUpgrade` from a Git branch, which then has to carry the change). A branch or tag
   of this repo, if not `main`.
3. **The orb provider**: its name, such as `homelab`. The user confirms creating it in a dialog
   and adds its orb types in Settings (step 3). To reuse one they have, ask where its token is
   and that it is this provider's, not another one's; the test thread in step 6 confirms it.
   Check its orb types now as in step 3, so any fix goes in this message.
4. **The apps platform**, which is always installed:
   - A domain for the apps, such as `apps.example.com`, in a zone on Cloudflare.
   - A Cloudflare API token with Zone → DNS → Edit and Zone → Zone → Read on that zone.
   - In the [tailnet policy](https://login.tailscale.com/admin/acls), `"tag:k8s-operator": []` and
     `"tag:k8s": ["tag:k8s-operator"]` under `tagOwners`, and a grant that lets the user reach
     the apps, such as
     `{"src": ["autogroup:member"], "dst": ["tag:k8s"], "ip": ["tcp:80", "tcp:443"]}`.
   - A Tailscale [OAuth client](https://login.tailscale.com/admin/settings/oauth) with the
     Devices Core and Auth Keys write scopes and the tag `tag:k8s-operator`, stored as
     `TS_OAUTH_CLIENT_ID` and `TS_OAUTH_CLIENT_SECRET`.
5. **A NAS** for paused orbs: an NFS export (server and path) writable by root or squashed to a
   user who can write. Use a new, empty directory: the server generates a new encryption key,
   and the snapshot gateway does not start on a directory another key encrypted.

### 1. The machines

Each machine needs NixOS on x86_64, **kernel 6.7+ or 6.6.23+** (the module refuses older ones; set
`boot.kernelPackages = pkgs.linuxPackages_latest;` if needed), outbound HTTPS, and 16 GB of memory
or more (`free -g` shows 15): each running orb reserves its size plus 128 MiB. The module opens
6443/tcp, 10250/tcp and 8472/udp for the other machines; on a machine with a public IP, block
them in its provider's firewall.

`nodeIP` is the IPv4 address the other machines reach it at: its LAN address at home (on the
default route, `ip -4 route get 1.1.1.1`, not a virbr0, docker0 or tailscale0 address), its public
one on a single cloud server. Without it, K3s exits when the network hands out a new IPv6 prefix.

### 2. The credentials

Write each credential to its file in `/var/lib/amp-orbs` on the server, passing it on standard
input, never on the command line. `amp-orbs-secrets.service` fails until all four are there.

```sh
ssh root@<server> 'install -d -m 700 /var/lib/amp-orbs'
printf '%s' "$ORB_PROVIDER_TOKEN" | ssh root@<server> 'umask 077; cat > /var/lib/amp-orbs/orb-provider-token'
# the same for $<Cloudflare token's variable> into cloudflare-api-token, $TS_OAUTH_CLIENT_ID into
# ts-oauth-client-id and $TS_OAUTH_CLIENT_SECRET into ts-oauth-client-secret
# on the server itself: replace `ssh root@<server>` with `sudo sh -c`
```

After step 4 has started K3s on the server, copy its `/var/lib/rancher/k3s/server/node-token` to
`/root/k3s-token` (mode 600) on every other machine, without printing it.

### 3. The orb provider

Create it with `manage_amp` (topic `orb_providers`, operation `create`, scope `personal`). The
token lands in `~/.local/share/amp/secrets.json` under `orb-provider-token@<Amp URL>`, such as
`orb-provider-token@https://ampcode.com/`. The next `create` overwrites it, so copy it right away,
without printing it, to `/var/lib/amp-orbs/orb-provider-token` on the server as in step 2:
`jq -r '<that key>' … | ssh root@<server> 'umask 077; cat > /var/lib/amp-orbs/orb-provider-token'`. In an Amp
orb, `create` is refused: have the user click **Add Provider** in
[Settings → Orbs](https://ampcode.com/settings/orbs) and store its `aop_live_…` token as the
secret `ORB_PROVIDER_TOKEN`.

The user then edits the provider in [Settings → Orbs](https://ampcode.com/settings/orbs) and adds
these types, `small` the default, named as `workers.types` in [`orbs.nix`](orbs.nix):

| Type | CPU | Memory |
| --- | --- | --- |
| `tiny` | 1 | 2 GiB |
| `small` | 2 | 4 GiB |
| `medium` | 4 | 8 GiB |
| `large` | 8 | 16 GiB |
| `xxlarge` | 16 | 32 GiB |

Check with `manage_amp` (topic `orb_providers`, operation `list`) that the type names are exactly
these, with `small` the default (`list` shows no CPU or memory): an orb of a misspelled type never
starts. Amp cannot rename a type; the user adds the right one and removes the wrong one.

### 4. Install

Check on the server that root can write to the export (on a squashed export the file
belongs to the anonymous user, which is fine):
`nix shell nixpkgs#nfs-utils -c sh -c 'd=$(mktemp -d) && mount -t nfs <server>:<path> $d && touch $d/t && ls -ln $d/t && rm $d/t; umount $d; rmdir $d'`.

Add this repo to the user's flake and the module to each machine, then deploy the server first,
then the apps machine, then the burst machines, the way the user deploys (`nixos-rebuild switch`, or commit and push for an auto-upgrade):

```nix
# flake.nix inputs
amp-k3s.url = "github:meln1k/amp-k3s-orb-provider/<branch or tag>";
# each machine's modules
amp-k3s.nixosModules.default
{
  services.amp-orbs = {
    enable = true;
    role = "server";  # or "apps" or "burst"
    nodeIP = "<its IPv4>";

    # the server:
    appsDomain = "<domain>";
    nas = { server = "<NAS IP>"; path = "/export/path"; };  # UniFi UNAS: /var/nfs/shared/<Shared_Drive_Name>

    # every other machine:
    # serverAddr = "https://<server IPv4>:6443";
    # tokenFile = "/root/k3s-token";
  };
}
```

The first build pulls Amp's chart. K3s then applies everything, and `amp-orbs-secrets.service`
creates the cluster's Secrets from the files. A first install takes 3 to 15 minutes, most of it
pulling images and waiting for the wildcard certificate (DNS-01 takes a
few minutes). Watch `kubectl get pods -A` and `kubectl -n kube-system get addon`. Every later
deploy upgrades.

### 5. Apps platform: DNS and access

1. **DNS.** Traefik's tailnet address is
   `kubectl -n traefik get svc traefik -o jsonpath='{.status.loadBalancer.ingress[*].ip}'`, the
   100.x one. If it stays empty for minutes, check the tailnet policy's `tagOwners` and
   `kubectl -n tailscale logs deploy/operator`. Point `*.<domain>` at it, DNS only (not proxied),
   with the Cloudflare API: the ID of the zone holding the domain (`example.com` for
   `apps.example.com`) from `GET /zones?name=<zone>`, then
   `GET /zones/<zone ID>/dns_records?name=*.<domain>`. A reinstall changes the address, so
   `PATCH /zones/<zone ID>/dns_records/<record ID>` an existing record, else
   `POST /zones/<zone ID>/dns_records`, with
   `{"type": "A", "name": "*.<domain>", "content": "<100.x address>", "proxied": false}`. Send the
   token on standard input: `printf 'Authorization: Bearer %s\n' "$TOKEN" | curl -H @- -H 'Content-Type: application/json' …`.
   Check with `dig +short x.<domain>`.
2. **Access.** The user's orbs act as the Kubernetes user `amp:<Amp user ID>`. The ID (`user_…`)
   is `$AMP_USER_ID` in the user's orb, or `.accounts[].userID` in
   `~/.local/share/amp/accounts.json` on a runner or the user's machine. The username, which only
   names the binding, is `ampUsername` from `get_current_user_identity` (module `amp`).

   ```sh
   kubectl -n apps create rolebinding amp-<Amp username> --role=agent --user=amp:<Amp user ID>
   # Compute tasks on the burst machines (docs/reference.md, Tasks).
   kubectl -n tasks create rolebinding amp-<Amp username> --role=agent --user=amp:<Amp user ID>
   ```

3. **Environment.** Store the output of `platform/agent-kubeconfig.sh` (run it on the server from
   a clone of this repo at the flake input's revision; it only reads the cluster), one line of JSON passed unchanged, as `APPS_KUBECONFIG` and the domain
   as `APPS_DOMAIN` with `manage_amp` (topic `environment_variables`, operation `set`, scope
   `personal`; neither is a credential), and read `APPS_KUBECONFIG` back with operation `get` to
   compare it with the script's output. Overwrite existing ones: a K3s reinstall changes the
   cluster's CA. Orbs load them after `amp orb restart-processes`, runner threads after the runner
   restarts.

### 6. Check and report

On the server, `systemctl status amp-orbs-secrets` succeeded, `kubectl -n kube-system get addon`
lists `amp-orbs`, the Job `substrate-bootstrap-<hash>` in `amp-orbs` completed, every pod in
`amp-orbs` and `ate-system` is Running on the server (atelet also on each burst machine), and `kubectl -n amp-orbs logs deploy/amp-orb-provider -c spawner` shows
`Orb provider started`. Also every pod in `cert-manager`, `tailscale`,
`traefik` and `registry` is Running on the apps machine (`kubectl get pods -A -o wide`), `kubectl -n traefik get certificate wildcard` is
Ready, `x.<domain>` resolves to Traefik's 100.x address, and `curl https://x.<domain>` from the
tailnet gets Traefik's 404 with a valid certificate. Last, start a thread on the provider with
`create_thread` (`orb_provider` its name, `orb_size` `small`, `project` `no-project`) that runs
`uname -a`. Its first spawn takes about 1.5 minutes; when the spawner log shows `Orb spawned` for
`amp-<its thread ID without T->`, this cluster serves the provider.

If something fails, read [Troubleshoot](docs/reference.md#troubleshoot) and the section of
[docs/reference.md](docs/reference.md) for that part before changing anything.

Tell the user all of these:

- **Copy `/var/lib/amp-orbs/snapshots.key` on the server somewhere safe.** It encrypts every
  paused orb; without it they are lost.
- Pick the provider under **Orb → Self-Hosted** in the thread composer, or make it the default
  under **Default Orb** in Settings → Orbs. To test it, start a thread on it, run a background
  process, wait until the orb pauses, then send another message: the process is still running.
- Add [`skills/deploying-k3s-apps`](skills/deploying-k3s-apps/SKILL.md)
  to their skills. Apps are at `https://<app>.<domain>`, and only threads on this provider can
  deploy them, because the cluster's API is reachable only from inside it.
