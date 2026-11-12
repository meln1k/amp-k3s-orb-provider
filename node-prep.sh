#!/bin/sh
# Run as root on every K3s node before installing the chart.
set -eu
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
echo ok
