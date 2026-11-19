#!/usr/bin/env bash
# Installs or upgrades everything: the orbs (Amp's chart through this overlay) and the apps
# platform (platform/). Safe to run again; a second run is an upgrade. See README.
#
#   APPS_DOMAIN=apps.example.com ./install.sh   # orbs and the apps platform
#   ./install.sh --orbs-only                     # orbs only
#
# It creates the gitignored s3.env and snapshots.key if they are missing. Each credential the
# cluster does not have yet comes from its environment variable or, without one, a hidden prompt:
#   ORB_PROVIDER_TOKEN                         the orb provider's token from Amp, or the file
#                                              /root/orb-provider-token
#   TS_OAUTH_CLIENT_ID, TS_OAUTH_CLIENT_SECRET a Tailscale OAuth client (apps platform)
#   CLOUDFLARE_API_TOKEN                       DNS edit on the apps' zone (apps platform)
set -euo pipefail
cd "$(dirname "$0")"

CHART=oci://us-central1-docker.pkg.dev/amp-prod-0/orb-provider/chart
CHART_VERSION=0.20261109.1946 # the version the overlay is checked against

die() { echo "install.sh: $*" >&2; exit 1; }
step() { printf '\n== %s\n' "$*"; }

# wait_until <seconds> <what> <command...>: retry the command every 5 s until it succeeds.
wait_until() {
	local end=$((SECONDS + $1)) what=$2
	shift 2
	until "$@" >/dev/null 2>&1; do
		((SECONDS < end)) || { echo "install.sh: timed out waiting for $what" >&2; return 1; }
		sleep 5
	done
}

# ensure_secret <namespace> <name> <key>=<variable>=<prompt>...: create the Secret unless it
# exists, each key from its environment variable or a hidden prompt.
ensure_secret() {
	local ns=$1 name=$2 spec key var value dir
	shift 2
	kubectl -n "$ns" get secret "$name" >/dev/null 2>&1 && return
	# Created plain, not applied, so platform/ stays the only one applying its namespaces.
	kubectl get namespace "$ns" >/dev/null 2>&1 || kubectl create namespace "$ns" >/dev/null
	dir=$(mktemp -d) # mode 700: the values never appear in a process's arguments
	for spec; do
		key=${spec%%=*} var=${spec#*=} var=${var%%=*}
		value=${!var:-}
		if [ -z "$value" ]; then
			{ true </dev/tty; } 2>/dev/null || die "secret $ns/$name is missing: set $var"
			read -rsp "${spec##*=}: " value </dev/tty
			printf '\n' >/dev/tty
			[ -n "$value" ] || die "${spec##*=} is empty"
		fi
		printf '%s' "$value" >"$dir/$key"
	done
	kubectl -n "$ns" create secret generic "$name" --from-file="$dir" >/dev/null
	rm -rf "$dir"
	echo "created secret $ns/$name"
}

orbs_only=false
case "${1:-}" in
"") ;;
--orbs-only) orbs_only=true ;;
*) die "usage: APPS_DOMAIN=<domain> $0 | $0 --orbs-only" ;;
esac

command -v kubectl >/dev/null || die "kubectl not found"
command -v helm >/dev/null || die "helm not found"
# Helm 4 only accepts post-renderers packaged as plugins.
helm version --short | grep -q '^v3\.' || die "need Helm 3, have $(helm version --short)"
# On a K3s server, K3s's kubectl finds the cluster on its own, Helm does not.
if [ -z "${KUBECONFIG:-}" ] && [ -r /etc/rancher/k3s/k3s.yaml ]; then
	export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
fi
kubectl get --raw /version >/dev/null || die "cannot reach the cluster; set KUBECONFIG"

if ! $orbs_only; then
	# On an upgrade, the domain the wildcard certificate was issued for.
	: "${APPS_DOMAIN:=$(kubectl -n traefik get certificate wildcard -o jsonpath='{.spec.dnsNames[0]}' 2>/dev/null || true)}"
	APPS_DOMAIN=${APPS_DOMAIN#\*.} # also when the certificate was cut to the wildcard alone
	[ -n "$APPS_DOMAIN" ] || die "set APPS_DOMAIN, such as APPS_DOMAIN=apps.example.com $0, or pass --orbs-only"
	[[ $APPS_DOMAIN =~ ^([a-z0-9]([a-z0-9-]*[a-z0-9])?\.)+[a-z]{2,}$ ]] ||
		die "APPS_DOMAIN must be a lowercase domain name, such as apps.example.com"
fi

step "Orbs"
if [ ! -e s3.env ]; then
	(umask 077; printf 'AWS_ACCESS_KEY_ID=%s\nAWS_SECRET_ACCESS_KEY=%s\n' \
		"$(openssl rand -hex 10)" "$(openssl rand -hex 24)" >s3.env)
	echo "created s3.env"
fi
if [ ! -e snapshots.key ]; then
	(umask 077; openssl rand -base64 32 >snapshots.key)
	echo "created snapshots.key: keep a copy outside the cluster, or paused orbs are lost with it"
fi
if [ -z "${ORB_PROVIDER_TOKEN:-}" ] && [ -r /root/orb-provider-token ]; then
	ORB_PROVIDER_TOKEN=$(cat /root/orb-provider-token)
fi
ensure_secret amp-orbs amp-orb-spawner \
	AMP_ORB_PROVIDER_TOKEN=ORB_PROVIDER_TOKEN='Amp provider token (aop_live_…)'
helm upgrade --install orb-provider "$CHART" --version "$CHART_VERSION" -n amp-orbs \
	-f values.yaml --post-renderer ./post-render.sh --wait --timeout 30m

if $orbs_only; then
	echo "Done. The orbs are installed; the apps platform was skipped."
	exit 0
fi

step "Apps platform for $APPS_DOMAIN"
ensure_secret tailscale operator-oauth client_id=TS_OAUTH_CLIENT_ID='Tailscale OAuth client ID' \
	client_secret=TS_OAUTH_CLIENT_SECRET='Tailscale OAuth client secret'
ensure_secret cert-manager cloudflare-api-token api-token=CLOUDFLARE_API_TOKEN='Cloudflare API token'

# The manifests name apps.example.com where the apps' domain goes.
apply() { kubectl kustomize "$1" | sed "s/apps\.example\.com/$APPS_DOMAIN/g" | kubectl apply -f -; }
out=$(apply platform)
printf '%s\n' "$out"
# CoreDNS reads the custom server blocks only when it starts.
if grep -Eq '^configmap/coredns-custom (created|configured)' <<<"$out"; then
	kubectl -n kube-system rollout restart deploy/coredns
fi

echo "waiting for cert-manager (K3s's Helm controller installs it)"
wait_until 600 "cert-manager's Deployments" kubectl -n cert-manager wait --for=condition=Available \
	deploy/cert-manager deploy/cert-manager-webhook deploy/cert-manager-cainjector --timeout=5s
# The webhook refuses requests until cainjector has given it its CA, a few seconds later.
wait_until 120 "cert-manager's webhook" apply platform/certs
echo "applied the issuer and certificates"

echo "waiting for Traefik's tailnet address"
ip_of_traefik() {
	kubectl -n traefik get svc traefik -o jsonpath='{range .status.loadBalancer.ingress[*]}{.ip}{"\n"}{end}' |
		grep -m1 -E '^[0-9]+(\.[0-9]+){3}$' # its IPv4 address, not the hostname or IPv6 entries
}
wait_until 300 "Traefik's tailnet address" ip_of_traefik || die "check the tailnet policy's tagOwners \
(README) and: kubectl -n tailscale logs deploy/operator"
ip=$(ip_of_traefik)

echo "waiting for the wildcard certificate (DNS-01 takes a few minutes)"
kubectl -n traefik wait --for=condition=Ready certificate/wildcard --timeout=10m >/dev/null ||
	die "check the Cloudflare token and: kubectl -n traefik describe certificate wildcard; \
kubectl -n traefik describe order; kubectl get challenges -A. A 429 rateLimited order: see Troubleshoot \
in docs/reference.md"

cat <<EOF

Done. The orbs and the apps platform are installed.

The DNS record for the apps, at your DNS provider (on Cloudflare, DNS only, not proxied):
  *.$APPS_DOMAIN  A  $ip

To let a user's orbs deploy apps, follow the README's step 5: a RoleBinding per user, and the
environment variables APPS_KUBECONFIG (./platform/agent-kubeconfig.sh) and APPS_DOMAIN=$APPS_DOMAIN.
EOF
