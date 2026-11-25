---
name: deploying-k3s-apps
description: Builds, deploys, rolls back and removes long-running apps on the self-hosted K3s cluster, served at https://<app>.$APPS_DOMAIN. Use when asked to deploy, update, roll back, debug or remove an app there, or to give an app a hostname, and runs compute-heavy tasks such as test sweeps on its burst machines.
---

# Deploying apps to the K3s cluster

An app is a Deployment, a Service and an Ingress in the namespace `apps`. You build its image
with Nix in the orb, from the app's `flake.nix`, and push it to the cluster's registry, and
Traefik serves it at `https://<app>.$APPS_DOMAIN` with a wildcard certificate. You have rights in
`apps`, and in `tasks` for compute jobs (see Compute tasks), nowhere else. The cluster refuses root containers, LoadBalancer and NodePort Services,
`externalIPs` and Tailscale annotations. Docker in the orb cannot build, and there is no other
builder, so an app with only a Dockerfile needs a `flake.nix` first.

Deploy only when the user asks for a deploy; a request to commit or push code is not one.

## Setup, once per orb

The kubeconfig's namespace is `apps`, so the commands in this skill omit `-n`.

```sh
: "${APPS_KUBECONFIG:?Set APPS_KUBECONFIG in Amp environment variables (platform/agent-kubeconfig.sh)}"
: "${APPS_DOMAIN:?Set APPS_DOMAIN in Amp environment variables, such as apps.example.com}"
mkdir -p ~/.kube ~/.config/nix
# No credential in it: kubectl gets a fresh token from `amp orb id-token` per command.
(umask 077; printf '%s' "$APPS_KUBECONFIG" > ~/.kube/config)
# The orb installs the cluster's kubectl as it starts; wait for it if the orb is seconds old.
for i in $(seq 30); do [ -x /usr/local/bin/kubectl ] && break; sleep 2; done
[ -x /usr/local/bin/kubectl ] || cat /var/log/kubectl-install.log
command -v nix >/dev/null || {
  curl -fsSL https://nixos.org/nix/install | sh -s -- --no-daemon
  . ~/.nix-profile/etc/profile.d/nix.sh; }
# gVisor cannot run Nix's build sandbox.
printf 'experimental-features = nix-command flakes\nsandbox = false\n' > ~/.config/nix/nix.conf
kubectl version   # no skew warning
kubectl auth whoami                   # amp:<your Amp user ID>
kubectl auth can-i create deployments # yes; "no" means the user has no RoleBinding in apps
kubectl -n tasks auth can-i create jobs # yes; needed only for Compute tasks
```

## Build and push

Each image is tagged with the commit it was built from, so commit first and never reuse a tag. A
new app gets its own directory in the workspace, such as `<workspace>/<app>`, with `git init`;
run the commands below from it. If `git commit` refuses, set `user.name` and `user.email` in
that repository, such as `Amp` and `amp@localhost`.

```sh
APP=crm   # lowercase letters, digits and dashes; also the hostname
# A new app: must print nothing. An old $APP-data volume would hand the app its data.
kubectl get deploy/$APP svc/$APP ingress/$APP pvc/$APP-data --ignore-not-found
# creates or updates flake.lock, and commits it if it changed, before the tag is taken
nix flake lock && git add flake.lock &&
  { git diff --cached --quiet -- flake.lock || git commit -qm 'Lock flake inputs' -- flake.lock; }
IMAGE=registry.registry.svc:8080/$APP:$(git rev-parse --short HEAD)
rm -f /tmp/$APP-digest /tmp/$APP-image   # Deploy reads the digest, so a failed run must not leave an older one
if [ -n "$(git status --porcelain)" ]; then echo 'Commit first (untracked files too)'; else
  # In the orb, Nix fails now and then with "unexpected EOF reading a line" (a gVisor bug);
  # a rerun continues where it stopped.
  for try in 1 2 3 4 5; do nix build .#image --out-link /tmp/$APP-image && break; done
  [ -e /tmp/$APP-image ] &&
  nix run nixpkgs#skopeo -- --insecure-policy copy --dest-tls-verify=false \
    --digestfile /tmp/$APP-digest docker-archive:/tmp/$APP-image "docker://$IMAGE" &&
  echo "pushed $IMAGE@$(cat /tmp/$APP-digest)" ||
  echo 'BUILD OR PUSH FAILED: nothing was pushed. Read the error above.' >&2
fi
```

The flake sees only files Git tracks, so commit everything the image needs.

### Default stack

Unless the user or the repository already chose one, build a web app with Remix 3
(https://remix.run, not Remix 2 or React Router) and keep its data in SQLite through
`node:sqlite`, backed up with Litestream (see SQLite with Litestream). Scaffold it with
`npx -y remix@latest new $APP`, then give `package.json` the `version` that `remix new` leaves
out, which Nix needs: `npm pkg set version=0.1.0 && npm install --package-lock-only`. Add a
`/healthz` route that returns `ok`. Remix 3 runs its TypeScript as is, so the image needs no build
step:

```nix
{
  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  outputs = { nixpkgs, ... }:
    let
      pkgs = nixpkgs.legacyPackages.x86_64-linux;
      nodejs = pkgs.nodejs_24;
      pkg = builtins.fromJSON (builtins.readFile ./package.json);
      app = pkgs.buildNpmPackage {
        pname = pkg.name;
        inherit (pkg) version;
        inherit nodejs;
        src = ./.;
        # After every change to package-lock.json: nix run nixpkgs#prefetch-npm-deps -- package-lock.json
        npmDepsHash = "sha256-...";
        dontNpmBuild = true;
      };
    in {
      packages.x86_64-linux.image = pkgs.dockerTools.buildLayeredImage {
        name = "app";
        extraCommands = "mkdir -m 1777 tmp";
        config = {
          User = "1000:1000";
          WorkingDir = "${app}/lib/node_modules/${pkg.name}";
          Env = [ "NODE_ENV=production" "PORT=8080" "DATABASE_PATH=/data/app.db" ];
          Cmd = [ "${nodejs}/bin/node" "--import" "remix/node-tsx" "server.ts" ];
        };
      };
    };
}
```

Keep `node_modules` in `.gitignore`. `ERROR: npmDepsHash is out of date` means the lockfile
changed: compute the hash again.

### Other apps

A static site keeps its pages in `www/`, with a file `www/healthz` containing `ok`, and this
`flake.nix`:

```nix
{
  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  outputs = { nixpkgs, ... }:
    let pkgs = nixpkgs.legacyPackages.x86_64-linux; in {
      packages.x86_64-linux.image = pkgs.dockerTools.buildLayeredImage {
        name = "app";
        config = {
          User = "1000:1000";
          Cmd = [ "${pkgs.busybox}/bin/httpd" "-f" "-p" "8080" "-h" "${./www}" ];
        };
      };
    };
}
```

For another app, build it as a package in the same flake and name it in `Cmd`. The image holds
only what `Cmd` and `contents` refer to: no shell, no `/tmp` and no CA certificates. Add
`extraCommands = "mkdir -m 1777 tmp";` if the app writes temporary files, and for HTTPS calls
`contents = [ pkgs.cacert ];` with `Env = [ "SSL_CERT_FILE=${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt" ];`
in `config`.

Deploying an existing name replaces that app.

The build runs in the orb, on its CPUs, and fetches what it can from cache.nixos.org. The
registry is reachable from the orb and the nodes only, not from apps.

## Manifest

Keep it in the app's repository as `deploy/k8s.yaml`; Deploy fills in `__APP__`, `__IMAGE__` and
`__HOST__`:

```yaml
apiVersion: apps/v1
kind: Deployment
metadata: {name: __APP__}
spec:
  replicas: 1
  revisionHistoryLimit: 10
  selector: {matchLabels: {app: __APP__}}
  template:
    metadata: {labels: {app: __APP__}}
    spec:
      securityContext: {runAsNonRoot: true, runAsUser: 1000, seccompProfile: {type: RuntimeDefault}}
      containers:
      - name: app
        image: __IMAGE__
        ports: [{name: http, containerPort: 8080}]
        readinessProbe: {httpGet: {path: /healthz, port: http}}
        resources:
          requests: {cpu: 10m, memory: 32Mi}   # a static site; size to the app
          limits: {memory: 64Mi}
        securityContext: {allowPrivilegeEscalation: false, capabilities: {drop: [ALL]}}
---
apiVersion: v1
kind: Service
metadata: {name: __APP__}
spec:
  selector: {app: __APP__}
  ports: [{name: http, port: 80, targetPort: http}]
---
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata: {name: __APP__}
spec:
  rules:
  - host: __HOST__
    http:
      paths:
      - {path: /, pathType: Prefix, backend: {service: {name: __APP__, port: {name: http}}}}
```

- Pod Security is `restricted`: keep both `securityContext` blocks, and use an image that works as
  UID 1000 (or set `runAsUser` to its numeric UID) and listens above port 1024.

- The pod gets traffic, and the rollout finishes, only once `GET /healthz` returns 2xx; point the
  `readinessProbe` at another path if the app serves that instead.
- Give every container requests and a memory limit of at least the request. Without them it gets
  50m and 128Mi; a memory request over 128Mi without a limit is refused, and so is a pod over the
  shared quota (`kubectl describe quota apps`). `kubectl top node` shows how much room each
  machine has left.
- The registry keeps each app's 5 newest tags plus every image a Deployment or its rollback
  history still names; older ones are pruned weekly.
- The Ingress needs no `tls` section: Traefik serves the wildcard certificate, which covers
  `<app>.$APPS_DOMAIN` but not `a.<app>.$APPS_DOMAIN`, and redirects HTTP to HTTPS.
- State that must survive a restart goes in a PersistentVolumeClaim, with
  `strategy: {type: Recreate}` on the Deployment. For a database, use SQLite with Litestream
  (below), not a database server.
- Apps reach each other by Service name, and the internet, but not the LAN or the rest of the
  cluster. That includes the Kubernetes API, and you cannot create ServiceAccounts or Roles, so
  an app that shows cluster state gets it from you: write it with kubectl into a ConfigMap the
  app mounts, and tell the user it is a snapshot.

## SQLite with Litestream

A PersistentVolumeClaim lives on one machine's disk only. An app that keeps data uses SQLite on
it, and Litestream streams every change to the cluster's backup gateway, which stores it
encrypted on the NAS. When the volume is new or lost, the app starts from the last backup. If
`kubectl get secret litestream` finds nothing, the cluster has no gateway: tell the user the data
has no backup.

Add this to `deploy/k8s.yaml`, with the app opening `/data/app.db` in WAL mode
(`PRAGMA journal_mode=WAL`) and leaving checkpoints to Litestream (`PRAGMA wal_autocheckpoint=0`
if the driver allows it). Keep a single replica: two writers corrupt the backup.

```yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata: {name: __APP__-data}
spec:
  accessModes: [ReadWriteOnce]
  resources: {requests: {storage: 1Gi}}
---
apiVersion: v1
kind: ConfigMap
metadata: {name: __APP__-litestream}
data:
  litestream.yml: |
    dbs:
    - path: /data/app.db
      replica:
        type: s3
        bucket: litestream
        path: __APP__
        endpoint: http://versitygw.backups.svc:7070
        region: us-east-1
```

In the Deployment, set `strategy: {type: Recreate}` and add to the pod spec (`containers` keeps
the app, which mounts `data` at `/data` too):

```yaml
      initContainers:
      # Restores the last backup when the volume has no database yet.
      - name: restore
        image: &litestream litestream/litestream:0.5.18@sha256:513bff62a88fc0c86c73d27333c41c54c89fe890a7c32a551600adff9309b11b
        # A new pod's NetworkPolicy takes a few seconds to apply, so retry for up to a minute.
        command: [sh, -c, '[ -e /data/app.db ] && { echo "restore: kept the existing database"; exit 0; }; for i in $(seq 30); do litestream restore -config /etc/litestream/litestream.yml -if-replica-exists /data/app.db && { [ -e /data/app.db ] && echo "restore: restored the database from its backup" || echo "restore: no backup, the app starts with an empty database"; exit 0; }; sleep 2; done; exit 1']
        envFrom: [{secretRef: {name: litestream}}]
        volumeMounts: &lsmounts
        - {name: data, mountPath: /data}
        - {name: litestream, mountPath: /etc/litestream}
        resources: &lsresources
          requests: {cpu: 20m, memory: 32Mi}
          limits: {memory: 128Mi}
        securityContext: &lssecurity {allowPrivilegeEscalation: false, capabilities: {drop: [ALL]}}
      # Runs next to the app for the pod's lifetime and replicates every change.
      - name: replicate
        image: *litestream
        restartPolicy: Always
        args: [replicate, -config, /etc/litestream/litestream.yml]
        envFrom: [{secretRef: {name: litestream}}]
        volumeMounts: *lsmounts
        resources: *lsresources
        securityContext: *lssecurity
      volumes:
      - {name: data, persistentVolumeClaim: {claimName: __APP__-data}}
      - {name: litestream, configMap: {name: __APP__-litestream}}
```

After the deploy, `kubectl logs deploy/$APP -c restore` says whether the pod kept, restored or
started without a database. A backup outlives its app, so on a new app's first deploy it must
say `no backup`; if it restored, an earlier app of the same name left that data: tell the user
before going on. `kubectl logs deploy/$APP -c replicate` shows the replica syncing, and
`kubectl exec deploy/$APP -c replicate -- litestream ltx -config /etc/litestream/litestream.yml
/data/app.db` lists what is backed up. To test a restore without touching the live database, run
`litestream restore -config /etc/litestream/litestream.yml -o /tmp/check.db /data/app.db` in that
container and query `/tmp/check.db`.

## Deploy

In a new shell, set `APP` and `IMAGE` again as in Build and push. The registry has no login, so
any orb could replace a tag: deploy the digest you pushed, never the tag.

```sh
REF=registry.registry.svc:8080/$APP@$(cat /tmp/$APP-digest)   # the image Build and push pushed
sed -e "s#__APP__#$APP#g" -e "s#__IMAGE__#$REF#" -e "s#__HOST__#$APP.$APPS_DOMAIN#" deploy/k8s.yaml | kubectl apply -f -
kubectl annotate deploy/$APP kubernetes.io/change-cause="$IMAGE" --overwrite
kubectl rollout status deploy/$APP --timeout=3m
# Traefik routes to a new pod or Ingress a few seconds after the rollout finishes; until then it
# answers 503 or 404, so retry for up to about 30 seconds.
curl -fsS --retry 15 --retry-delay 2 --retry-all-errors "https://$APP.$APPS_DOMAIN/healthz"
# Pods of the previous version may still be terminating, so only the others count.
test "$(kubectl get pod -l app=$APP -o go-template='{{range .items}}{{if not .metadata.deletionTimestamp}}{{(index .status.containerStatuses 0).imageID}}{{"\n"}}{{end}}{{end}}' | sort -u)" = \
  "$REF" && echo 'digest ok'
```

Then fetch the page or endpoint the change affects with `curl -fsS https://$APP.$APPS_DOMAIN/<path>`
and check its content (for a UI change, also take a screenshot with agent-browser and look at
it), and for an app with a PersistentVolumeClaim check that its data is still there. Tell the user the URL, the image and its
commit, and what you checked; if the repository has no remote, say that the commit and
`deploy/k8s.yaml` exist only in this orb. Users open the URL over the tailnet only; from the orb
it resolves to Traefik inside the cluster.

If the rollout stalls, read `kubectl describe pod -l app=$APP`, `kubectl logs deploy/$APP` and
`kubectl get events --sort-by=.lastTimestamp`, then roll back. A first deploy has nothing to roll
back to: fix forward, or remove the app.

## Secrets

Credentials live in Secrets, which the Deployment reads with `envFrom: [{secretRef: {name: <secret>}}]`
or `valueFrom.secretKeyRef`. Inspect them with `kubectl describe secret`, which shows only keys and
sizes; never print a value.

- A value you generate goes straight from the generator into the Secret:

  ```sh
  kubectl create secret generic $APP-session --from-literal=SESSION_SECRET="$(openssl rand -hex 32)"
  ```

- A value the user or a third party provides, such as an API key, stays out of the thread: give
  the user this command, with the names filled in, to run in the orb's Terminal tab, where they
  type it at a hidden prompt:

  ```sh
  read -rsp 'Value: ' V; printf '\n'; kubectl create secret generic <app>-stripe --from-literal=STRIPE_KEY="$V"; unset V
  ```

Give each provided value its own Secret, so replacing one touches only it. Pods read Secrets when
they start: run `kubectl rollout restart deploy/$APP` after a change.

## Compute tasks

Short, CPU-heavy work the user asks to run in the cluster, such as a test or simulation sweep,
runs as a Job in the namespace `tasks`, on the burst machines, never in `apps`. Build and push
its image as in Build and push, and set `REF` as in Deploy. While every burst machine is off, its pods stay
Pending: tell the user to boot one. A shutdown stops the pods within 9.5 minutes, and the Job
runs them again from the start, so write results somewhere outside the pod (logs, or the
internet) as they come.

```sh
NAME=sweep-$(date +%s)
kubectl -n tasks apply -f - <<EOF
apiVersion: batch/v1
kind: Job
metadata: {name: $NAME}
spec:
  completions: 16          # one pod per shard; JOB_COMPLETION_INDEX is 0 to completions-1
  parallelism: 8
  completionMode: Indexed
  backoffLimitPerIndex: 1
  ttlSecondsAfterFinished: 86400
  podFailurePolicy:        # a burst machine's shutdown does not count as a failure
    rules: [{action: Ignore, onPodConditions: [{type: DisruptionTarget, status: "True"}]}]
  template:
    spec:
      restartPolicy: Never
      securityContext: {runAsNonRoot: true, runAsUser: 1000, seccompProfile: {type: RuntimeDefault}}
      containers:
      - name: task
        image: $REF
        resources:
          requests: {cpu: "4", memory: 4Gi}   # size to the work; no CPU limit, it uses free cores
          limits: {memory: 4Gi}
        securityContext: {allowPrivilegeEscalation: false, capabilities: {drop: [ALL]}}
EOF
# Until the Job completes or fails; `kubectl wait` would wait out its timeout on a failure.
until kubectl -n tasks get job/$NAME -o jsonpath='{.status.conditions[?(@.status=="True")].type}' |
  grep -qwE 'Complete|Failed'; do sleep 30; done
kubectl -n tasks get job/$NAME   # COMPLETIONS, and STATUS Complete or Failed
kubectl -n tasks logs -l job-name=$NAME --prefix --tail=-1
```

All tasks together may request 64 CPU and 96 GiB (`kubectl -n tasks describe quota tasks`). A
failed Job keeps its pods for `kubectl -n tasks logs`; delete it with `kubectl -n tasks delete job
$NAME` when done.

## Roll back

```sh
kubectl rollout history deploy/$APP           # revisions, with their change-cause
kubectl rollout undo deploy/$APP              # the previous revision
kubectl rollout undo deploy/$APP --to-revision=3
kubectl rollout status deploy/$APP --timeout=3m
```

`rollout undo` changes only the pod template, and the next deploy applies the manifest again, so
fix the code too.

## Remove

Ask the user first: deleting a PersistentVolumeClaim deletes the app's data. Its Litestream backup
stays on the NAS, and a later app of the same name restores from it.

```sh
sed "s#__APP__#$APP#g" deploy/k8s.yaml | kubectl delete -f -
```
