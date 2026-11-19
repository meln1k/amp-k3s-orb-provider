---
name: deploying-k3s-apps
description: Builds, deploys, rolls back and removes long-running apps on the self-hosted K3s cluster, served at https://<app>.$APPS_DOMAIN. Use when asked to deploy, update, roll back, debug or remove an app there, or to give an app a hostname.
---

# Deploying apps to the K3s cluster

An app is a Deployment, a Service and an Ingress in the namespace `apps`. BuildKit in the cluster
builds its image and pushes it to the cluster's registry, and Traefik serves it at
`https://<app>.$APPS_DOMAIN` with a wildcard certificate. You have rights in `apps` only. The
cluster refuses root containers, LoadBalancer and NodePort Services, `externalIPs` and Tailscale
annotations, and Docker in the orb cannot build or push its images.

Deploy only when the user asks for a deploy; a request to commit or push code is not one.

## Setup, once per orb

The kubeconfig's namespace is `apps`, so the commands in this skill omit `-n`.

```sh
: "${APPS_KUBECONFIG:?Set APPS_KUBECONFIG in Amp environment variables (platform/agent-kubeconfig.sh)}"
: "${APPS_DOMAIN:?Set APPS_DOMAIN in Amp environment variables, such as apps.example.com}"
mkdir -p ~/.kube ~/.buildkit
# No credential in it: kubectl gets a fresh token from `amp orb id-token` per command.
(umask 077; printf '%s' "$APPS_KUBECONFIG" > ~/.kube/config)
command -v kubectl >/dev/null || {
  # afterwards `kubectl version`: if the client is more than one minor version from the server,
  # run these two lines again with stable-1.<server minor>.txt in place of stable.txt
  curl -fsSLo /tmp/kubectl "https://dl.k8s.io/release/$(curl -fsSL https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
  sudo install /tmp/kubectl /usr/local/bin/kubectl; }
command -v buildctl >/dev/null ||
  curl -fsSL https://github.com/moby/buildkit/releases/download/v0.35.0/buildkit-v0.35.0.linux-amd64.tar.gz |
  sudo tar xz -C /usr/local bin/buildctl
# BuildKit accepts only clients with this certificate.
(umask 077; for f in ca.crt tls.crt tls.key; do
  kubectl get secret buildkit-client -o go-template="{{index .data \"$f\" | base64decode}}" > ~/.buildkit/$f
done)
kubectl auth whoami                   # amp:<your Amp user ID>
kubectl auth can-i create deployments # yes; "no" means the user has no RoleBinding in apps
```

## Build and push

Each image is tagged with the commit it was built from, so commit first and never reuse a tag. A
new app gets its own directory in the workspace, such as `<workspace>/<app>`, with `git init`;
run the commands below from it. If `git commit` refuses, set `user.name` and `user.email` in
that repository, such as `Amp` and `amp@localhost`.

```sh
APP=crm   # lowercase letters, digits and dashes; also the hostname
kubectl get deploy/$APP 2>/dev/null   # a new app's name must be free: deploying replaces this one
test -z "$(git status --porcelain)" || { echo 'Commit first'; exit 1; }   # untracked files too
IMAGE=registry.registry.svc:5000/$APP:$(git rev-parse --short HEAD)
buildctl --addr tcp://buildkitd.buildkit.svc.cluster.local:1234 \
  --tlscacert ~/.buildkit/ca.crt --tlscert ~/.buildkit/tls.crt --tlskey ~/.buildkit/tls.key \
  build --frontend dockerfile.v0 --local context=. --local dockerfile=. \
  --output "type=image,name=$IMAGE,push=true" --metadata-file /tmp/$APP-build.json
jq -r '."containerimage.digest"' /tmp/$APP-build.json   # the pushed digest
```

Build steps reach the internet, where base images come from, but not the LAN or the cluster. Only
BuildKit and the nodes reach the registry, not the orb.

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
  UID 1000 (or set `runAsUser` to its numeric UID) and listens above port 1024. A static site
  keeps its pages in `www/`, with a file `www/healthz` containing `ok`, and this Dockerfile:

  ```dockerfile
  FROM busybox:1.37
  COPY www /www
  USER 1000:1000
  CMD ["httpd", "-f", "-p", "8080", "-h", "/www"]
  ```

- The pod gets traffic, and the rollout finishes, only once `GET /healthz` returns 2xx; point the
  `readinessProbe` at another path if the app serves that instead.
- Give every container requests and a memory limit of at least the request. Without them it gets
  50m and 128Mi; a memory request over 128Mi without a limit is refused, and so is a pod over the
  shared quota (`kubectl describe quota apps`).
- The Ingress needs no `tls` section: Traefik serves the wildcard certificate, which covers
  `<app>.$APPS_DOMAIN` but not `a.<app>.$APPS_DOMAIN`, and redirects HTTP to HTTPS.
- State that must survive a restart goes in a PersistentVolumeClaim, with
  `strategy: {type: Recreate}` on the Deployment.
- Apps reach each other by Service name, and the internet, but not the LAN or the rest of the
  cluster.

## Deploy

In a new shell, set `APP` and `IMAGE` again as in Build and push.

```sh
sed -e "s#__APP__#$APP#g" -e "s#__IMAGE__#$IMAGE#" -e "s#__HOST__#$APP.$APPS_DOMAIN#" deploy/k8s.yaml | kubectl apply -f -
kubectl annotate deploy/$APP kubernetes.io/change-cause="$IMAGE" --overwrite
kubectl rollout status deploy/$APP --timeout=3m
curl -fsS "https://$APP.$APPS_DOMAIN/healthz"
test "$(kubectl get pod -l app=$APP -o jsonpath='{range .items[*]}{.status.containerStatuses[0].imageID}{"\n"}{end}' | sort -u)" = \
  "registry.registry.svc:5000/$APP@$(jq -r '."containerimage.digest"' /tmp/$APP-build.json)" && echo 'digest ok'
```

Then fetch the page or endpoint the change affects with `curl -fsS https://$APP.$APPS_DOMAIN/<path>`
and check its content (for a UI change, also take a screenshot), and for an app with a
PersistentVolumeClaim check that its data is still there. Tell the user the URL, the image and its
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

## Roll back

```sh
kubectl rollout history deploy/$APP           # revisions, with their change-cause
kubectl rollout undo deploy/$APP              # the previous revision
kubectl rollout undo deploy/$APP --to-revision=3
kubectl rollout status deploy/$APP --timeout=3m
```

`rollout undo` changes only the pod template, and the next deploy applies the manifest again, so
fix the code too.

## Run on a schedule

Only when the user asks, and only if the cluster runs the optional downscaler (ask the user; you
cannot see it). It scales the app to zero outside the window:

```sh
kubectl annotate deploy/$APP downscaler/uptime="Mon-Fri 08:00-20:00 Europe/Berlin" --overwrite
kubectl annotate deploy/$APP downscaler/uptime-   # run all the time again
```

Use the user's time zone (ask if unknown; the orb's clock is UTC), and deploy and check inside the
window: outside it the URL does not answer.

## Remove

Ask the user first: deleting a PersistentVolumeClaim deletes the app's data.

```sh
sed "s#__APP__#$APP#g" deploy/k8s.yaml | kubectl delete -f -
```
