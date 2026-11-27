# A burst machine's shutdown waits until its orbs are paused and their snapshots are on the server
# (docs/reference.md, Machine roles). amp-orbs-shutdown-drain runs `shutdown-drain serve`; built with
# writeShellApplication (nixos.nix), so it runs under `set -euo pipefail`.
#
# serve: uncordons the node if a drain of ours left it cordoned, then holds a logind delay lock
#   for shutdown and runs `watch` under it.
# watch: polls logind's PreparingForShutdown; when a shutdown waits, runs `drain`, then exits,
#   which releases the lock. A cancelled shutdown uncordons the node and keeps watching under the
#   same lock, so a shutdown right after it still drains.

kubeconfig=/var/lib/rancher/k3s/agent/kubelet.kubeconfig
cert=/var/lib/rancher/k3s/agent/client-kubelet.crt
# The K3s agent writes it on its first start, after this service starts.
until [ -e "$cert" ]; do sleep 5; done
# The kubelet's identity, system:node:<name>, is the only Node it may change.
node=$(openssl x509 -in "$cert" -noout -subject -nameopt multiline |
  sed -n 's/^ *commonName *= *system:node://p')
tty=/dev/tty12
prev_vt=""
was_cancelled=0

kc() { k3s kubectl --kubeconfig "$kubeconfig" --request-timeout=10s "$@"; }

# Pods of orb workers on this node, from the API. Fails when the API does not answer.
workers() {
  local j
  j=$(kc get pods -n amp-orbs -l ate.dev/worker-pool --field-selector spec.nodeName="$node" -o json) &&
    jq -r '.items[].metadata.name' <<<"$j"
}

# Seconds the oldest snapshot on this node has waited to be uploaded, 0 when none; fails when
# atelet or its metric cannot be read.
undurable() {
  local id ip m
  id=$(k3s crictl pods --namespace ate-system --name atelet --state ready -q | head -n 1)
  [ -n "$id" ] || return 1
  ip=$(k3s crictl inspectp "$id" | jq -r .status.network.ip)
  # Read in full first: piped, awk's early exit fails curl on a page of more than a few KB.
  m=$(curl -fsS --max-time 5 "http://$ip:9090/metrics") || return 1
  awk '/^atelet_snapshot_undurable_age_max_seconds[{ ]/ { print $NF; found = 1; exit } END { exit !found }' <<<"$m"
}

# logind's PreparingForShutdown: "b true" while a shutdown waits for delay locks. Only an
# explicit answer counts, so a D-Bus hiccup neither starts nor cancels a drain.
shutdown_is() {
  busctl get-property org.freedesktop.login1 /org/freedesktop/login1 \
    org.freedesktop.login1.Manager PreparingForShutdown | grep -qx "b $1"
}

# Progress on text console 12; nothing else is on screen once the desktop session has ended.
screen() {
  [ -w "$tty" ] || return 0
  printf '\033[?25l\033[H\033[2J\n  %s is shutting down\n\n  %s\n\n  %s\n  %s\n' "$node" "$1" "${2:-}" "${3:-}" >"$tty" || true
}
busy() { screen "$1" "Orbs on this machine are being paused and their snapshots uploaded" "to the server. Please do not switch it off."; }

# Shows console 12, remembering the one on screen (the desktop's), in the background so a
# console that does not switch cannot hold up the drain.
to_console() {
  prev_vt=$(timeout 5 fgconsole 2>/dev/null) || prev_vt=""
  (setfont -C "$tty" "${CONSOLE_FONT:-}" 2>/dev/null || true; timeout 5 chvt 12 || true) &
}
back_console() {
  if [ -w "$tty" ]; then printf '\033[?25h' >"$tty" || true; fi
  if [ -n "$prev_vt" ] && [ "$prev_vt" != 12 ]; then (timeout 5 chvt "$prev_vt" || true) & fi
}

uncordon() {
  local by
  by=$(kc get node "$node" -o json | jq -er '.metadata.annotations["amp-orbs/drained-by"] // ""') || return 1
  if [ "$by" = shutdown ]; then
    kc patch node "$node" --type merge -p '{"spec":{"unschedulable":null},"metadata":{"annotations":{"amp-orbs/drained-by":null}}}' >/dev/null || return 1
    echo "uncordoned $node"
  fi
}

# Cordons the node, marked as ours, unless it already was cordoned (then a boot leaves it so).
# Someone cordoning it by hand during our drain still finds our mark, so a cancel or the next
# boot uncordons it.
cordon() {
  local j
  j=$(kc get node "$node" -o json) || return 1
  if [ "$(jq -r '.spec.unschedulable // false' <<<"$j")" = true ]; then
    echo "$node was already cordoned"
    return 0
  fi
  kc patch node "$node" --type merge -p '{"spec":{"unschedulable":true},"metadata":{"annotations":{"amp-orbs/drained-by":"shutdown"}}}' >/dev/null
}

# Evicts this node's task pods, so their Jobs see a disruption, not a failure, and run them
# elsewhere (skills/deploying-k3s-apps, Compute tasks).
evict_tasks() {
  local j p
  j=$(kc get pods -n tasks --field-selector spec.nodeName="$node" -o json) || return 0
  for p in $(jq -r '.items[] | select(.metadata.deletionTimestamp == null) | .metadata.name' <<<"$j"); do
    jq -n --arg p "$p" '{apiVersion: "policy/v1", kind: "Eviction", metadata: {name: $p, namespace: "tasks"}}' |
      kc create --raw "/api/v1/namespaces/tasks/pods/$p/eviction" -f - >/dev/null && echo "evicted task pod $p"
  done
}

# The shutdown was cancelled: uncordon, unless another shutdown begins meanwhile (watch then
# drains again), and go back to the desktop. The lock stays held throughout.
cancel() {
  was_cancelled=1
  echo "shutdown cancelled; uncordoning"
  screen "Shutdown cancelled."
  until uncordon; do
    if shutdown_is true; then return 0; fi
    sleep 5
  done
  back_console
}

drain() {
  local start tries=0 w n el deleted=0 age zeros=0 unknown_since=""

  echo "shutdown: cordoning $node"
  until cordon; do
    if shutdown_is false; then cancel; return 0; fi
    tries=$((tries + 1))
    if [ "$tries" -ge 6 ]; then
      echo "the API does not answer; shutting down without pausing orbs"
      screen "The cluster does not answer; shutting down without pausing orbs."
      return 0
    fi
    sleep 10
  done
  start=$SECONDS
  to_console
  busy "Stopping new orbs from starting here..."
  evict_tasks || true

  # The provider counts a cordoned node as draining: it pauses the orbs on it and deletes their
  # workers. Workers still there after 10 minutes are deleted; each pauses its orb as it exits.
  # After 20 minutes, also while the API does not answer, it goes on without them.
  while :; do
    if shutdown_is false; then cancel; return 0; fi
    el=$((SECONDS - start))
    if [ "$el" -ge 1200 ]; then
      echo "orbs still not paused after $el s; going on without them"
      break
    fi
    if ! w=$(workers); then
      busy "Pausing orbs: the cluster does not answer ($el s)"
      sleep 5
      continue
    fi
    [ -n "$w" ] || break
    w=$(tr '\n' ' ' <<<"$w")
    n=$(wc -w <<<"$w")
    if [ "$el" -ge 600 ] && [ "$deleted" = 0 ]; then
      echo "deleting workers: $w"
      # shellcheck disable=SC2086
      if kc delete pod -n amp-orbs $w --wait=false >/dev/null; then deleted=1; fi
    fi
    [ $((el % 30)) -lt 5 ] && echo "waiting for orbs to pause: $n workers left"
    busy "Pausing orbs: $n left ($el s)"
    sleep 5
  done
  echo "orbs paused after $((SECONDS - start)) s; waiting for their snapshots to upload"

  # Three zero readings in a row, at least 10 s, longer than atelet waits before an upload.
  while [ "$zeros" -lt 3 ]; do
    if shutdown_is false; then cancel; return 0; fi
    el=$((SECONDS - start))
    if age=$(undurable); then
      unknown_since=""
      if [ "$age" = 0 ]; then zeros=$((zeros + 1)); else zeros=0; fi
      [ $((el % 30)) -lt 5 ] && [ "$age" != 0 ] && echo "oldest snapshot not uploaded yet: $age s old"
      busy "Uploading snapshots: the oldest has waited $age s ($el s)"
    else
      zeros=0
      unknown_since=${unknown_since:-$SECONDS}
      if [ $((SECONDS - unknown_since)) -ge 180 ]; then
        echo "ERROR: cannot read atelet_snapshot_undurable_age_max_seconds for 3 minutes; shutting down without knowing whether snapshots are uploaded"
        screen "Cannot tell whether the snapshots are uploaded; shutting down."
        return 0
      fi
      busy "Uploading snapshots: waiting for atelet ($el s)"
    fi
    sleep 5
  done
  echo "snapshots uploaded after $((SECONDS - start)) s; shutting down"
  screen "All orbs paused and uploaded after $((SECONDS - start)) s. Shutting down."
}

# Polled rather than subscribed to, so no shutdown can slip in before a subscription. drain runs
# outside any condition, so errexit stays on in it.
watch_shutdown() {
  while :; do
    if shutdown_is true; then
      was_cancelled=0
      drain
      [ "$was_cancelled" = 1 ] || exit 0
    fi
    sleep 2
  done
}

case "${1:-}" in
  serve)
    [ -n "$node" ] || { echo "cannot read the node name from the kubelet certificate"; exit 1; }
    # Restarted after a drain while the shutdown still waits on other delay locks: keep the
    # node cordoned.
    if shutdown_is true; then echo "shutting down; leaving $node cordoned"; exec sleep infinity; fi
    # Before taking the lock, so it cannot undo a drain that started meanwhile. Until the API
    # answers no orb can start here, so there is nothing to protect yet.
    until uncordon; do sleep 10; done
    exec systemd-inhibit --what=shutdown --mode=delay --who=amp-orbs \
      --why="Pausing orbs and uploading their snapshots" "$0" watch
    ;;
  watch) watch_shutdown ;;
  *) echo "usage: $0 serve" >&2; exit 2 ;;
esac
