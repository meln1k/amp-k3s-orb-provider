# VM test of a burst machine's shutdown drain (shutdown-drain/) with the real unit, logind and
# systemd. K3s is a stub that keeps the node, its orb workers and task pods in files under
# /var/lib/fake; atelet's metric is a file served on 127.0.0.1:9090. tests/cluster.nix runs the
# same drain against a real cluster. Run it with KVM, as tests/flake.nix says.
{ pkgs }:
let
  fake = "/var/lib/fake";
  k3s = pkgs.writeShellScriptBin "k3s" ''
    PATH=${pkgs.lib.makeBinPath [ pkgs.jq pkgs.coreutils pkgs.gnugrep ]}
    s=${fake}
    echo "$*" >> $s/log
    if [ "$1" = crictl ]; then
      case "$*" in
        *"pods --namespace ate-system --name atelet"*) echo atelet0 ;;
        *inspectp*) echo '{"status":{"network":{"ip":"127.0.0.1"}}}' ;;
      esac
      exit 0
    fi
    case "$*" in
      *"get node turing -o json"*)
        jq -n --arg a "$(cat $s/annotation)" --argjson u "$(cat $s/unschedulable)" \
          '{spec: {unschedulable: $u}, metadata: {annotations: (if $a == "" then {} else {"amp-orbs/drained-by": $a} end)}}' ;;
      *"patch node turing"*'"unschedulable":true'*) echo true > $s/unschedulable; echo shutdown > $s/annotation ;;
      *"patch node turing"*'"unschedulable":null'*) echo false > $s/unschedulable; : > $s/annotation ;;
      *"get pods -n amp-orbs -l ate.dev/worker-pool"*)
        jq -Rn '{items: [inputs | select(length > 0) | {metadata: {name: .}}]}' < $s/workers ;;
      *"get pods -n tasks"*)
        jq -Rn '{items: [inputs | select(length > 0) | {metadata: {name: .}}]}' < $s/tasks ;;
      *"create --raw /api/v1/namespaces/tasks/pods/"*/eviction*)
        cat > /dev/null; u="$*"; p=''${u##*/pods/}; p=''${p%%/eviction*}; grep -vx "$p" $s/tasks > $s/tasks.new || true; mv $s/tasks.new $s/tasks ;;
      *"delete pod -n amp-orbs"*) ;;
      *) echo "UNEXPECTED $*" >> $s/log; exit 1 ;;
    esac
  '';
in
pkgs.testers.runNixOSTest {
  name = "amp-orbs-shutdown-drain";
  nodes.turing = { lib, ... }: {
    imports = [ ../nixos.nix ];
    networking.hostName = "turing";
    services.amp-orbs = {
      enable = true;
      role = "burst";
      nodeIP = "192.168.1.2";
      serverAddr = "https://192.168.1.1:6443";
      tokenFile = "/root/k3s-token";
    };
    services.k3s.enable = lib.mkForce false;
    services.k3s.package = lib.mkForce k3s;
    # The kubelet's client certificate and the state a drain left before this boot.
    systemd.services.fake-cluster = {
      wantedBy = [ "multi-user.target" ];
      before = [ "amp-orbs-shutdown-drain.service" ];
      requiredBy = [ "amp-orbs-shutdown-drain.service" ];
      path = [ pkgs.openssl ];
      serviceConfig = { Type = "oneshot"; RemainAfterExit = true; };
      script = ''
        mkdir -p /var/lib/rancher/k3s/agent ${fake}/www
        cd /var/lib/rancher/k3s/agent
        [ -e client-kubelet.crt ] || openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes \
          -keyout client-kubelet.key -out client-kubelet.crt -subj "/O=system:nodes/CN=system:node:turing" -days 1
        cd ${fake}
        [ -e annotation ] && exit 0
        echo shutdown > annotation; echo true > unschedulable; : > workers; : > tasks; : > log
        echo 'atelet_snapshot_undurable_age_max_seconds{otel_scope_name="atelet"} 0' > www/metrics
        # Many KB after it, as atelet's real page has.
        seq 20000 | sed 's/^/# padding /' >> www/metrics
      '';
    };
    systemd.services.fake-atelet = {
      wantedBy = [ "multi-user.target" ];
      after = [ "fake-cluster.service" ];
      serviceConfig.ExecStart = "${pkgs.python3}/bin/python3 -m http.server 9090 --bind 127.0.0.1 --directory ${fake}/www";
    };
  };

  testScript = ''
    def state(name):
        return turing.succeed(f"cat ${fake}/{name}").strip()

    def metric(age):
        turing.succeed(f"echo 'atelet_snapshot_undurable_age_max_seconds{{otel_scope_name=\"atelet\"}} {age}' > ${fake}/www/metrics; seq 20000 | sed 's/^/# padding /' >> ${fake}/www/metrics")

    def armed():
        turing.wait_until_succeeds("systemd-inhibit --list --no-legend | grep -q 'amp-orbs.*shutdown.*delay'", timeout=90)

    def on_screen(text):
        turing.wait_until_succeeds("[ $(fgconsole) = 12 ]", timeout=15)
        turing.wait_until_succeeds(f"grep -aqF '{text}' /dev/vcs12", timeout=30)

    turing.start()

    with subtest("a boot uncordons a node our drain cordoned, then holds the lock"):
        turing.wait_for_unit("amp-orbs-shutdown-drain.service")
        turing.wait_until_succeeds("journalctl -u amp-orbs-shutdown-drain | grep -q 'uncordoned turing'")
        assert state("unschedulable") == "false" and state("annotation") == ""
        armed()
        # A suspend would lose the orbs.
        turing.succeed("systemd-inhibit --list --no-legend | grep -q 'amp-orbs.*sleep.*block'")

    with subtest("a restart, as on a switch, does not drain"):
        turing.succeed("systemctl restart amp-orbs-shutdown-drain")
        armed()
        assert state("unschedulable") == "false"
        turing.fail("journalctl -u amp-orbs-shutdown-drain | grep -q cordoning")

    with subtest("a node cordoned by hand stays cordoned after the service starts"):
        turing.succeed("echo true > ${fake}/unschedulable; systemctl restart amp-orbs-shutdown-drain")
        armed()
        assert state("unschedulable") == "true"
        turing.succeed("echo false > ${fake}/unschedulable")

    with subtest("a shutdown cancelled during the drain uncordons, goes back to the desktop and keeps the lock"):
        turing.succeed("echo w1 > ${fake}/workers")
        pid = turing.succeed("systemctl show -p MainPID --value amp-orbs-shutdown-drain").strip()
        turing.succeed("shutdown -h +1")
        turing.wait_until_succeeds("journalctl -u amp-orbs-shutdown-drain | grep -q 'cordoning turing'", timeout=120)
        assert state("unschedulable") == "true" and state("annotation") == "shutdown"
        on_screen("Pausing orbs")
        turing.succeed("shutdown -c")
        turing.wait_until_succeeds("journalctl -u amp-orbs-shutdown-drain | grep -q 'shutdown cancelled'", timeout=30)
        # The same process keeps the lock: a shutdown right after still drains.
        turing.succeed("systemd-inhibit --list --no-legend | grep -q 'amp-orbs.*shutdown.*delay'")
        turing.wait_until_succeeds("[ $(cat ${fake}/unschedulable) = false ]", timeout=30)
        assert state("annotation") == ""
        turing.wait_until_succeeds("[ $(fgconsole) = 1 ]", timeout=15)
        assert turing.succeed("systemctl show -p MainPID --value amp-orbs-shutdown-drain").strip() == pid
        turing.succeed(": > ${fake}/workers")

    with subtest("a shutdown waits for the orbs to pause and their snapshots to upload"):
        turing.succeed("echo w1 > ${fake}/workers; echo w2 >> ${fake}/workers; echo t1 > ${fake}/tasks")
        metric(40)
        turing.execute("systemctl poweroff --no-block")
        turing.wait_until_succeeds("[ $(cat ${fake}/unschedulable) = true ]", timeout=60)
        assert state("annotation") == "shutdown"
        turing.wait_until_succeeds("[ -z \"$(cat ${fake}/tasks)\" ]", timeout=30)
        on_screen("turing is shutting down")
        on_screen("Pausing orbs: 2 left")
        turing.screenshot("pausing")
        turing.succeed("sleep 15")  # still up while workers remain
        turing.succeed(": > ${fake}/workers")
        turing.wait_until_succeeds("journalctl -u amp-orbs-shutdown-drain | grep -q 'waiting for their snapshots'", timeout=30)
        on_screen("Uploading snapshots: the oldest has waited 40 s")
        turing.screenshot("uploading")
        turing.succeed("sleep 15")  # still up while a snapshot waits
        metric(0)
        turing.wait_for_shutdown()

    with subtest("the next boot uncordons the node"):
        turing.start()
        turing.wait_until_succeeds("journalctl -b -u amp-orbs-shutdown-drain | grep -q 'uncordoned turing'")
        assert state("unschedulable") == "false"
        armed()
        turing.fail("grep -q UNEXPECTED ${fake}/log")
  '';
}
