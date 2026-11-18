#!/bin/sh
# Run as root on every K3s node, best before installing K3s: `node-prep.sh server` on the server,
# `node-prep.sh` on agents. On a node already running K3s, restart it afterwards (running pods and
# orbs keep running): `systemctl restart k3s`, or `k3s-agent` on agents.
set -eu
dir=$(cd "$(dirname "$0")" && pwd)
case "${1:-}" in
"") server=false ;;
server) server=true ;;
*) echo "usage: $0 [server]" >&2; exit 1 ;;
esac
[ "$(stat -fc %T /sys/fs/cgroup)" = cgroup2fs ] || { echo "need cgroup v2" >&2; exit 1; }
[ "$(sysctl -n user.max_user_namespaces)" -gt 0 ] || { echo "need user namespaces" >&2; exit 1; }
# atelet mounts each orb's rootfs with overlayfs "lowerdir+": Linux 6.7+, or 6.6.23+ (backport).
# On older kernels every orb fails to start with "while creating overlay superblock: invalid argument".
uname -r | awk -F'[.+-]' '{ok = $1>6 || ($1==6 && $2>=7) || ($1==6 && $2==6 && $3>=23)} !ok {exit 1}' ||
	{ echo "need Linux 6.7+ or 6.6.23+ (overlayfs lowerdir+), have $(uname -r)" >&2; exit 1; }
cat > /etc/sysctl.d/99-amp-orbs.conf <<'CONF'
# gVisor mirrors every memory mapping of an orb into one host process.
vm.max_map_count = 4194304
# Substrate's kind setup enables these for gVisor pod-to-pod loopback networking.
net.ipv4.conf.all.proxy_arp = 1
net.ipv6.conf.all.proxy_ndp = 1
fs.inotify.max_user_instances = 8192
fs.inotify.max_user_watches = 1048576
CONF
sysctl -e --system >/dev/null

# The apps platform (platform/): nodes pull app images from the in-cluster registry's fixed
# ClusterIP. Unused, and harmless, on an install with --orbs-only.
mkdir -p /etc/rancher/k3s
if [ ! -e /etc/rancher/k3s/registries.yaml ]; then
	cat > /etc/rancher/k3s/registries.yaml <<'CONF'
# Written by node-prep.sh: app images from the apps platform's registry (platform/registry.yaml).
mirrors:
  "registry.registry.svc:5000":
    endpoint: ["http://10.43.0.50:5000"]
CONF
elif ! grep -q 'registry.registry.svc:5000' /etc/rancher/k3s/registries.yaml; then
	echo "add to /etc/rancher/k3s/registries.yaml under mirrors:" >&2
	echo '  "registry.registry.svc:5000": {endpoint: ["http://10.43.0.50:5000"]}' >&2
fi
# The server's API also accepts the Amp ID tokens orbs mint (platform/amp-auth.yaml). Agents
# refuse kube-apiserver flags, so only the server gets this.
if $server; then
	install -m 0600 "$dir/platform/amp-auth.yaml" /etc/rancher/k3s/amp-auth.yaml
	mkdir -p /etc/rancher/k3s/config.yaml.d
	cat > /etc/rancher/k3s/config.yaml.d/50-amp-apps.yaml <<'CONF'
# Written by node-prep.sh: the API accepts orbs' Amp ID tokens (platform/amp-auth.yaml).
kube-apiserver-arg+:
  - authentication-config=/etc/rancher/k3s/amp-auth.yaml
CONF
fi
echo ok
