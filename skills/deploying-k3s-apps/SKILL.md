---
name: deploying-k3s-apps
description: Builds, pushes, deploys and rolls back long-running apps on a self-hosted K3s cluster (namespace apps, served by Traefik at https://<app>.$APPS_DOMAIN). Use when asked to deploy, ship, update, roll back, debug or remove an app on the K3s cluster, or to give an app a hostname there.
---

# Deploying apps to the K3s cluster

Each app is a Deployment, a Service and an Ingress in the namespace `apps`, served by Traefik at
`https://<app>.$APPS_DOMAIN` with a wildcard certificate. Images are built by BuildKit in the
cluster and pushed to the cluster's registry. You have rights in `apps` only; you cannot see
nodes or other namespaces, and the cluster refuses root containers, LoadBalancer and NodePort
Services, `externalIPs` and Tailscale annotations. Docker inside the orb cannot build or push
these images.

Pushing code does not deploy it. Build and deploy only when the user asks for a deploy; a request
to commit, push or prepare a change is not one.

## Setup, once per orb

```sh
: "${APPS_KUBECONFIG:?Set APPS_KUBECONFIG in Amp environment variables (platform/agent-kubeconfig.sh)}"
: "${APPS_DOMAIN:?Set APPS_DOMAIN in Amp environment variables, such as apps.example.com}"
mkdir -p ~/.kube ~/.buildkit
# No credential in it: kubectl mints a fresh Amp ID token with `amp orb id-token` per command.
(umask 077; printf '%s' "$APPS_KUBECONFIG" > ~/.kube/config)
command -v kubectl >/dev/null || {
  # within one minor version of the server: `kubectl version` shows both once it is installed;
  # if they differ by more, install again with stable-1.<server minor>.txt in place of stable.txt
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

The kubeconfig's context defaults to the namespace `apps`, so the commands below omit `-n`.

## Build and push

Commit first, and tag the image with the commit, so every image maps to code. Never reuse a tag.
For a new app without a repository, create a directory named after the app in the workspace and
`git init` it; if `git commit` refuses, set `user.name` and `user.email`.

```sh
APP=crm   # lowercase letters, digits and dashes; also the hostname
test -z "$(git status --porcelain)" || { echo 'Commit first'; exit 1; }   # untracked files too
IMAGE=registry.registry.svc:5000/$APP:$(git rev-parse --short HEAD)
buildctl --addr tcp://buildkitd.buildkit.svc.cluster.local:1234 \
  --tlscacert ~/.buildkit/ca.crt --tlscert ~/.buildkit/tls.crt --tlskey ~/.buildkit/tls.key \
  build --frontend dockerfile.v0 --local context=. --local dockerfile=. \
  --output "type=image,name=$IMAGE,push=true"
```

The orb cannot reach the registry itself (it is plain HTTP on port 5000); only BuildKit and the
nodes use it. The Dockerfile's base images come from public registries. Build steps can reach the
internet, but not the LAN or the rest of the cluster.

## Manifest

Keep it in the app's repository, such as `deploy/k8s.yaml`, with `__APP__`, `__IMAGE__` and
`__HOST__` where the app name, image and hostname go:

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
          requests: {cpu: 10m, memory: 32Mi}   # size to the app; see below
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

- The cluster enforces Pod Security `restricted`: keep the two `securityContext` blocks, and use
  an image that works as UID 1000 (or set `runAsUser` to the image's numeric UID) and listens on
  a port above 1024. For static files, `FROM busybox:1.37`, `COPY www /www`, `USER 1000:1000` and
  `CMD ["httpd", "-f", "-p", "8080", "-h", "/www"]` works, with a file `www/healthz` (such as
  `ok`) for the readiness probe.
- The app must answer `GET /healthz` with a 2xx status, or change `readinessProbe.httpGet.path`
  to a path it serves. Until the probe passes, the pod gets no traffic and the rollout times out.
- The Ingress needs no `tls` section or Secret: Traefik serves every app with the wildcard
  certificate and redirects HTTP to HTTPS. It covers one level, `crm.$APPS_DOMAIN`, not
  `a.crm.$APPS_DOMAIN`.
- Set requests and a memory limit on every container, the limit at least the request, sized to
  the app: a static site needs about 10m CPU and 32Mi. A
  container without them gets 50m and 128Mi, and one with a memory request over 128Mi but no
  limit is refused. Apps share a quota (`kubectl describe quota apps`); a pod over it is refused.
- State that must survive a restart goes in a PersistentVolumeClaim, with `strategy: {type:
  Recreate}` on the Deployment.
- Credentials go in a Secret, never in the repo or the manifest (see [Secrets](#secrets)).
- Apps reach each other by Service name and the internet, but not the LAN or the rest of the
  cluster.

## Deploy

In a new shell, set `APP` and `IMAGE` again as in Build and push.

```sh
sed -e "s#__APP__#$APP#g" -e "s#__IMAGE__#$IMAGE#" -e "s#__HOST__#$APP.$APPS_DOMAIN#" deploy/k8s.yaml | kubectl apply -f -
kubectl annotate deploy/$APP kubernetes.io/change-cause="$IMAGE" --overwrite
kubectl rollout status deploy/$APP --timeout=3m
curl -fsS "https://$APP.$APPS_DOMAIN/healthz"
# registry…/$APP@sha256:…, must match the digest buildctl pushed
kubectl get pod -l app=$APP -o jsonpath='{.items[*].status.containerStatuses[*].imageID}'
```

A finished rollout and a healthy `/healthz` do not prove the change works: also open the page or
call the endpoint the change affects. On a redeploy of an app with a PersistentVolumeClaim, check
that its existing data is still there. Then tell the user the app's URL, the deployed image and
its commit, and what you checked.

From the orb, the app's name resolves to Traefik inside the cluster. Users reach the same URL over
the tailnet, where it resolves to Traefik's 100.x address, so it works only for people on the
tailnet.

If the rollout does not finish, read `kubectl describe pod -l app=$APP`, `kubectl logs
deploy/$APP` and `kubectl get events --sort-by=.lastTimestamp`, then roll back. A first deploy
has no earlier revision: fix forward, or remove the app.

## Secrets

Keep credentials in Secrets, and pass them to the app with `envFrom: [{secretRef: {name: crm}}]`
or `valueFrom.secretKeyRef` in the Deployment. Never print a value: `kubectl describe secret`
shows only the keys and sizes, while `kubectl get secret -o yaml` shows the values.

- **A value you generate**, such as a session key, goes from the generator straight into the
  Secret:

  ```sh
  kubectl create secret generic $APP-session --from-literal=SESSION_SECRET="$(openssl rand -hex 32)"
  ```

- **A value the user or a third party provides**, such as an API key, must not pass through the
  thread. Do not ask for it in chat. Give the user this command to run in the orb's Terminal
  tab, where they type the value at a hidden prompt:

  ```sh
  read -rsp 'Value: ' V; printf '\n'; kubectl create secret generic crm-stripe --from-literal=STRIPE_KEY="$V"; unset V
  ```

Give each provided value its own Secret, so replacing it means deleting and creating only that
one. An app reads its Secrets when its pods start, so after a change run `kubectl rollout restart
deploy/$APP`.

## Roll back

```sh
kubectl rollout history deploy/$APP           # revisions, with their change-cause
kubectl rollout undo deploy/$APP              # the previous revision
kubectl rollout undo deploy/$APP --to-revision=3
kubectl rollout status deploy/$APP --timeout=3m
```

`rollout undo` changes only the pod template. The next deploy applies the manifest again, so fix
forward from the code and deploy as above.

## Run on a schedule

Only when the user asks. If the cluster runs the optional downscaler (ask the user; you cannot see
its namespace), it scales an app to zero outside a time window and back up inside it:

```sh
kubectl annotate deploy/$APP downscaler/uptime="Mon-Fri 08:00-20:00 Europe/Berlin" --overwrite
kubectl annotate deploy/$APP downscaler/uptime-   # run all the time again
```

Use the user's time zone, and ask when you do not know it: the orb's clock is UTC. Outside the
window the app has no pods and its URL does not answer, so deploy and check it inside the window.

## Remove

Ask the user first: deleting a PersistentVolumeClaim deletes the app's data.

```sh
sed "s#__APP__#$APP#g" deploy/k8s.yaml | kubectl delete -f -
```
