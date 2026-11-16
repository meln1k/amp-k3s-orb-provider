#!/bin/sh
# Prints the kubeconfig orbs deploy apps with, on one line, for the Amp environment variable
# APPS_KUBECONFIG:
#   ./platform/agent-kubeconfig.sh | amp secrets set APPS_KUBECONFIG --workspace --env --data-file -
# It holds no secret: for every command, kubectl asks `amp orb id-token` in the orb for a fresh
# 10-minute token, which the API accepts as amp:<Amp user ID> (amp-auth.yaml).
# Its server is the API's in-cluster name, which only orbs on this cluster reach.
set -eu
ca=$(kubectl -n apps get configmap kube-root-ca.crt -o jsonpath='{.data.ca\.crt}' | base64 | tr -d '\n')
[ -n "$ca" ] || { echo "configmap apps/kube-root-ca.crt is missing; apply platform first" >&2; exit 1; }
# kubectl's exec credential plugin, as a shell command; it fails if amp cannot mint a token.
cmd='t=$(amp orb id-token --audience k3s-apps) && printf '\''{"apiVersion":"client.authentication.k8s.io/v1","kind":"ExecCredential","status":{"token":"%s"}}'\'' "$t"'
cmd=$(printf '%s' "$cmd" | sed 's/\\/\\\\/g; s/"/\\"/g') # as a JSON string
printf '{"apiVersion":"v1","kind":"Config","clusters":[{"name":"k3s","cluster":{"server":"https://kubernetes.default.svc.cluster.local","certificate-authority-data":"%s"}}],"users":[{"name":"amp","user":{"exec":{"apiVersion":"client.authentication.k8s.io/v1","interactiveMode":"Never","command":"sh","args":["-c","%s"]}}}],"contexts":[{"name":"apps","context":{"cluster":"k3s","user":"amp","namespace":"apps"}}],"current-context":"apps"}\n' "$ca" "$cmd"
