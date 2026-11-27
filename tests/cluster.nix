# VM test of a real three-machine K3s cluster built from nixos.nix: a server, an apps machine and
# a burst machine with preferOrbs. It runs offline, so the orbs themselves (Amp's control plane and
# images) and the apps platform's Helm charts do not start; everything else is the real thing:
# - each machine joins through the module's firewall and gets its labels and taints;
# - pods land where the namespaces' annotations and the orb workers' affinity send them;
# - what an agent (amp:<user>) may do, and the ValidatingAdmissionPolicies around it;
# - amp-orbs-ckpt-memory lifts memory.high on a checkpoint cgroup;
# - the burst machine's shutdown drain against the real API, with the kubelet's credentials, and
#   a stand-in for atelet's metrics page (the real atelet needs Substrate's images);
# - the server drops a stale amp-* manifest link before K3s starts.
# Run it with KVM, as tests/flake.nix says.
{ pkgs }:
let
  inherit (pkgs) lib;
  token = pkgs.writeText "k3s-token" "test-token";

  testImage = pkgs.dockerTools.buildImage {
    name = "test.local/pause";
    tag = "local";
    copyToRoot = pkgs.buildEnv { name = "test-image-env"; paths = [ pkgs.tini pkgs.coreutils ]; };
    config.Entrypoint = [ "/bin/tini" "--" ];
  };
  # Serves a metrics page like atelet's: the metric, then many KB of other series.
  ateletImage = pkgs.dockerTools.buildImage {
    name = "test.local/atelet";
    tag = "local";
    copyToRoot = pkgs.buildEnv { name = "test-atelet-env"; paths = [ pkgs.busybox ]; };
    config.Cmd = [ "/bin/sh" "-c" ''
      mkdir -p /www
      { echo 'atelet_snapshot_undurable_age_max_seconds{otel_scope_name="atelet"} 40'; seq 20000 | sed 's/^/# padding /'; } > /www/metrics
      exec httpd -f -p 9090 -h /www
    '' ];
  };

  # A pod that passes the restricted Pod Security level of apps and tasks.
  pod = ns: name: extra: lib.recursiveUpdate {
    apiVersion = "v1";
    kind = "Pod";
    metadata = { inherit name; namespace = ns; };
    spec = {
      terminationGracePeriodSeconds = 5;
      securityContext = { runAsNonRoot = true; runAsUser = 65534; seccompProfile.type = "RuntimeDefault"; };
      containers = [{
        name = "main";
        image = "test.local/pause:local";
        imagePullPolicy = "Never";
        command = [ "sleep" "inf" ];
        securityContext = { allowPrivilegeEscalation = false; capabilities.drop = [ "ALL" ]; };
      }];
    };
  } extra;
  # Shaped like an orb worker as the patched provider makes it (provider.nix): only on gVisor
  # nodes, preferring amp-orbs/prefer-orbs=true with weight 100, no toleration for the taints.
  # Without the preference: the same worker before the patch.
  orbWorker' = prefer: name: pod "amp-orbs" name {
    metadata.labels."ate.dev/worker-pool" = "tiny";
    spec.affinity.nodeAffinity = {
      requiredDuringSchedulingIgnoredDuringExecution.nodeSelectorTerms = [{
        matchExpressions = [{ key = "ate.dev/sandboxClass"; operator = "Exists"; }];
      }];
    } // lib.optionalAttrs prefer {
      preferredDuringSchedulingIgnoredDuringExecution = [{
        weight = 100;
        preference.matchExpressions = [{ key = "amp-orbs/prefer-orbs"; operator = "In"; values = [ "true" ]; }];
      }];
    };
  };
  orbWorker = orbWorker' true;
  json = name: value: pkgs.writeText "${name}.json" (builtins.toJSON value);

  manifests = lib.mapAttrs json {
    orb1 = orbWorker "orb1";
    orb2 = orbWorker "orb2";
    control = orbWorker' false "control";
    # Books nearly all of the burst machine's allocatable CPU (3) and memory (about 1.9 Gi), so
    # its resource score is near 0 whatever the server runs (the scorer counts 100m and 200Mi
    # for every container without requests): without the preference the server wins.
    filler = lib.recursiveUpdate (pod "default" "filler" { spec.nodeName = "burst"; }) {
      spec.containers = [{
        name = "main";
        image = "test.local/pause:local";
        imagePullPolicy = "Never";
        command = [ "sleep" "inf" ];
        resources.requests = { cpu = "2600m"; memory = "1400Mi"; };
      }];
    };
    drainTask = pod "tasks" "drain-task" { };
    atelet = {
      apiVersion = "v1";
      kind = "Pod";
      # The drain finds it as it finds atelet: crictl's --name atelet matches it.
      metadata = { name = "atelet-fake"; namespace = "ate-system"; labels.app = "atelet-fake"; };
      spec = {
        nodeName = "burst";
        terminationGracePeriodSeconds = 1;
        containers = [{
          name = "main";
          image = "test.local/atelet:local";
          imagePullPolicy = "Never";
          # The name ate-system's ate-system-observability NetworkPolicy lets in.
          ports = [{ name = "prometheus"; containerPort = 9090; }];
        }];
      };
    };
    app = pod "apps" "app" { };
    task = pod "tasks" "task" { };
    registryPod = pod "registry" "probe" { };
    worker = lib.recursiveUpdate (orbWorker "worker") { spec.nodeName = "burst"; };
    svcOk = { apiVersion = "v1"; kind = "Service"; metadata = { name = "ok"; namespace = "apps"; }; spec.ports = [{ port = 80; }]; };
    svcExternalIPs = { apiVersion = "v1"; kind = "Service"; metadata = { name = "ext"; namespace = "apps"; }; spec = { ports = [{ port = 80; }]; externalIPs = [ "192.168.1.5" ]; }; };
    svcTailscale = { apiVersion = "v1"; kind = "Service"; metadata = { name = "ts"; namespace = "apps"; annotations."tailscale.com/expose" = "true"; }; spec.ports = [{ port = 80; }]; };
    roleOk = { apiVersion = "rbac.authorization.k8s.io/v1"; kind = "Role"; metadata = { name = "app-reader"; namespace = "apps"; }; rules = [{ apiGroups = [ "" ]; resources = [ "pods" ]; verbs = [ "get" "list" "watch" ]; }]; };
    roleSecrets = { apiVersion = "rbac.authorization.k8s.io/v1"; kind = "Role"; metadata = { name = "app-secrets"; namespace = "apps"; }; rules = [{ apiGroups = [ "" ]; resources = [ "secrets" ]; verbs = [ "get" ]; }]; };
    rbOk = { apiVersion = "rbac.authorization.k8s.io/v1"; kind = "RoleBinding"; metadata = { name = "app-reader"; namespace = "apps"; }; roleRef = { apiGroup = "rbac.authorization.k8s.io"; kind = "Role"; name = "app-reader"; }; subjects = [{ kind = "ServiceAccount"; name = "app"; namespace = "apps"; }]; };
    rbAgent = { apiVersion = "rbac.authorization.k8s.io/v1"; kind = "RoleBinding"; metadata = { name = "steal"; namespace = "apps"; }; roleRef = { apiGroup = "rbac.authorization.k8s.io"; kind = "Role"; name = "agent"; }; subjects = [{ kind = "ServiceAccount"; name = "app"; namespace = "apps"; }]; };
    tokenSecret = { apiVersion = "v1"; kind = "Secret"; type = "kubernetes.io/service-account-token"; metadata = { name = "tok"; namespace = "apps"; annotations."kubernetes.io/service-account.name" = "app"; }; };
  };

  common = role: { config, ... }: {
    imports = [ ../nixos.nix ];
    # The server and the burst machine get the same CPUs, so only the preference tells them apart
    # for orbs; 4 fit a task's default 1-CPU request (platform/tasks.yaml) next to the 1 CPU the
    # module reserves.
    virtualisation = { cores = if role == "apps" then 2 else 4; memorySize = if role == "server" then 4096 else 2048; diskSize = 6144; };
    services.amp-orbs = { enable = true; inherit role; nodeIP = config.networking.primaryIPAddress; };
    services.k3s = {
      images = [ config.services.k3s.package.airgap-images testImage ateletImage ];
      # The test network is eth1; eth0 only carries the driver's default route.
      extraFlags = [ "--flannel-iface eth1" ];
    };
  };
  agent = role: { nodes, ... }: {
    imports = [ (common role) ];
    services.amp-orbs = {
      serverAddr = "https://${nodes.server.networking.primaryIPAddress}:6443";
      tokenFile = "${token}";
    };
  };
in
pkgs.testers.runNixOSTest {
  name = "amp-orbs-cluster";
  nodes = {
    server = {
      imports = [ (common "server") ];
      services.amp-orbs.appsDomain = "apps.test";
      services.k3s.tokenFile = token;
      # Stand-ins for the credentials of README, step 2.
      systemd.tmpfiles.rules = map (f: "f /var/lib/amp-orbs/${f} 0600 root root - test")
        [ "orb-provider-token" "cloudflare-api-token" "ts-oauth-client-id" "ts-oauth-client-secret" ];
    };
    apps = agent "apps";
    burst = {
      imports = [ (agent "burst") ];
      services.amp-orbs.preferOrbs = true;
    };
  };

  testScript = ''
    import json

    def kc(cmd):
        return server.succeed(f"k3s kubectl {cmd}")

    def apply(path):
        kc(f"apply -f {path}")

    def node_of(ns, name):
        server.wait_until_succeeds(f"k3s kubectl -n {ns} wait --for=condition=Ready pod/{name} --timeout=10s", timeout=180)
        return kc(f"-n {ns} get pod {name} -o jsonpath='{{.spec.nodeName}}'").strip()

    def agent(cmd):
        return server.execute(f"k3s kubectl --as=amp:user_test {cmd} 2>&1")

    def denied(cmd, policy):
        server.wait_until_succeeds(f"(k3s kubectl --as=amp:user_test {cmd} 2>&1 || true) | grep -q 'ValidatingAdmissionPolicy .{policy}.'", timeout=60)

    def node_json(name):
        return json.loads(kc(f"get node {name} -o json"))

    start_all()

    with subtest("the three machines join and are Ready"):
        server.wait_for_unit("k3s")
        for n in ["server", "apps", "burst"]:
            server.wait_until_succeeds(f"k3s kubectl get node {n}", timeout=300)
            server.wait_until_succeeds(f"k3s kubectl wait --for=condition=Ready node/{n} --timeout=10s", timeout=300)
        server.wait_for_unit("amp-orbs-secrets")
        kc("-n amp-orbs get secret amp-orb-spawner")

    with subtest("each machine has its role's labels and taints"):
        expect = {
            "server": ({"amp-orbs/runs-apps": "true"}, []),
            "apps": ({"amp-orbs/role": "apps", "amp-orbs/runs-apps": "true"}, ["amp-orbs/apps=true:PreferNoSchedule"]),
            "burst": ({"amp-orbs/role": "burst", "amp-orbs/prefer-orbs": "true"}, []),
        }
        for n, (labels, taints) in expect.items():
            j = node_json(n)
            got = j["metadata"]["labels"]
            assert got.get("ate.dev/sandboxClass") == "gvisor", f"{n}: {got}"
            for k in ["amp-orbs/role", "amp-orbs/runs-apps", "amp-orbs/prefer-orbs"]:
                assert got.get(k) == labels.get(k), f"{n}: {k}={got.get(k)}, expected {labels.get(k)}"
            got_taints = sorted(f"{t['key']}={t.get('value', str())}:{t['effect']}" for t in j["spec"].get("taints", [])
                                if not t["key"].startswith("node.kubernetes.io/"))
            assert got_taints == taints, f"{n}: taints {got_taints}, expected {taints}"

    with subtest("an orb worker goes to the preferOrbs machine, and would not with the burst taint"):
        apply("${manifests.filler}")
        assert node_of("default", "filler") == "burst"
        apply("${manifests.control}")
        assert node_of("amp-orbs", "control") == "server", "without the preference the busy burst machine should lose"
        apply("${manifests.orb1}")
        assert node_of("amp-orbs", "orb1") == "burst"
        kc("delete pod filler --wait=false")
        kc("-n amp-orbs delete pod control --wait=false")
        # Why preferOrbs drops the taint (nixos.nix): an untolerated PreferNoSchedule taint
        # outweighs the preferred affinity.
        kc("taint node burst amp-orbs/burst=true:PreferNoSchedule")
        apply("${manifests.orb2}")
        assert node_of("amp-orbs", "orb2") == "server"
        kc("taint node burst amp-orbs/burst=true:PreferNoSchedule-")
        kc("-n amp-orbs delete pod orb1 orb2 --wait=false")

    with subtest("the namespaces' annotations place apps, tasks and the platform"):
        for ns in ["apps", "tasks", "registry"]:
            server.wait_until_succeeds(f"k3s kubectl get namespace {ns}", timeout=300)
        apply("${manifests.app}")
        apply("${manifests.task}")
        apply("${manifests.registryPod}")
        app = json.loads(kc("-n apps get pod app -o json"))
        assert app["spec"]["nodeSelector"] == {"amp-orbs/runs-apps": "true"}, app["spec"].get("nodeSelector")
        assert node_of("apps", "app") in ["server", "apps"]
        assert node_of("tasks", "task") == "burst"
        assert node_of("registry", "probe") == "apps"
        # The API reaches the burst machine's kubelet (port 10250) for exec.
        kc("-n tasks exec task -- true")
        kc("-n tasks delete pod task")

    with subtest("an agent gets its Roles and nothing else"):
        kc("-n apps create rolebinding amp-test --role=agent --user=amp:user_test")
        kc("-n tasks create rolebinding amp-test --role=agent --user=amp:user_test")
        kc("create clusterrolebinding amp-test-nodes --clusterrole=amp-agent-nodes --user=amp:user_test")
        for can in ["create deployments -n apps", "get secrets -n apps", "create jobs -n tasks", "list nodes"]:
            server.succeed(f"k3s kubectl --as=amp:user_test auth can-i {can}")
        for cannot in ["patch nodes", "get secrets -n amp-orbs", "get pods -n ate-system", "create pods -n kube-system",
                       "create services -n tasks", "create clusterrolebindings", "create deployments -n default"]:
            server.fail(f"k3s kubectl --as=amp:user_test auth can-i {cannot}")

    with subtest("the admission policies keep agents' apps behind Traefik and their Roles read-only"):
        denied("apply -f ${manifests.svcExternalIPs}", "apps-behind-traefik")
        denied("apply -f ${manifests.svcTailscale}", "apps-behind-traefik")
        denied("apply -f ${manifests.roleSecrets}", "app-roles")
        denied("apply -f ${manifests.rbAgent}", "app-rolebindings")
        denied("apply -f ${manifests.tokenSecret}", "app-token-secrets")
        for ok in ["${manifests.svcOk}", "${manifests.roleOk}", "${manifests.rbOk}"]:
            status, out = agent(f"apply -f {ok}")
            assert status == 0, out
        # The Role and RoleBinding policies apply to agents only, not to the platform's admins.
        apply("${manifests.roleSecrets}")

    with subtest("amp-orbs-ckpt-memory lifts memory.high on a checkpoint cgroup"):
        d = "/sys/fs/cgroup/kubepods.slice/test-_ckpt"
        burst.succeed(f"mkdir {d} && echo 104857600 > {d}/memory.high")
        burst.wait_until_succeeds(f"[ $(cat {d}/memory.high) = max ]", timeout=30)
        burst.succeed(f"rmdir {d}")

    with subtest("a burst machine's shutdown cordons it, evicts tasks and waits for its orbs and snapshots"):
        burst.wait_until_succeeds("systemd-inhibit --list --no-legend | grep -q 'amp-orbs.*shutdown.*delay'", timeout=120)
        burst.succeed("systemd-inhibit --list --no-legend | grep -q 'amp-orbs.*sleep.*block'")
        # The stand-in replaces the real atelet, which comes up offline only now and then.
        kc("-n ate-system patch daemonset atelet --type merge -p '{\"spec\":{\"template\":{\"spec\":{\"nodeSelector\":{\"test/no-atelet\":\"true\"}}}}}'")
        server.wait_until_succeeds("! k3s kubectl -n ate-system get pods -l app=atelet --field-selector spec.nodeName=burst -o name | grep -q .", timeout=120)
        apply("${manifests.atelet}")
        assert node_of("ate-system", "atelet-fake") == "burst"
        apply("${manifests.drainTask}")
        assert node_of("tasks", "drain-task") == "burst"
        apply("${manifests.worker}")
        assert node_of("amp-orbs", "worker") == "burst"
        burst.execute("systemctl poweroff --no-block")
        server.wait_until_succeeds("[ \"$(k3s kubectl get node burst -o jsonpath='{.spec.unschedulable}')\" = true ]", timeout=60)
        assert node_json("burst")["metadata"]["annotations"].get("amp-orbs/drained-by") == "shutdown"
        server.wait_until_succeeds("! k3s kubectl -n tasks get pod drain-task", timeout=90)
        burst.wait_until_succeeds("journalctl -u amp-orbs-shutdown-drain | grep -q 'evicted task pod drain-task'")
        burst.succeed("sleep 15")  # still up while the worker remains
        burst.succeed("journalctl -u amp-orbs-shutdown-drain | grep -q 'waiting for orbs to pause: 1 workers left'")
        kc("-n amp-orbs delete pod worker --wait=false")
        burst.wait_until_succeeds("journalctl -u amp-orbs-shutdown-drain | grep -q 'orbs paused after'", timeout=60)
        # Still up while a snapshot waits, reading the multi-KB page through the pod's IP.
        burst.wait_until_succeeds("journalctl -u amp-orbs-shutdown-drain | grep -q 'oldest snapshot not uploaded yet: 40 s old'", timeout=60)
        kc("-n ate-system exec atelet-fake -- sed -i 's/} 40$/} 0/' /www/metrics")
        # Checked after the next boot: the machine powers down milliseconds after the line.
        burst.wait_for_shutdown()

    with subtest("its next boot uncordons it"):
        burst.start()
        burst.succeed("journalctl -b -1 -u amp-orbs-shutdown-drain | grep -q 'snapshots uploaded after'")
        server.wait_until_succeeds("[ -z \"$(k3s kubectl get node burst -o jsonpath='{.spec.unschedulable}')\" ]", timeout=300)
        assert "amp-orbs/drained-by" not in node_json("burst")["metadata"].get("annotations", {})

    with subtest("the server drops a stale manifest link before K3s starts"):
        m = "/var/lib/rancher/k3s/server/manifests"
        server.succeed(f"ln -s /nonexistent {m}/amp-stale.yaml")
        server.succeed("systemctl restart k3s")
        server.wait_for_unit("k3s")
        server.fail(f"test -L {m}/amp-stale.yaml")
        server.succeed(f"test -e {m}/amp-apps-apps.yaml && test -e {m}/amp-orbs.yaml")
  '';
}
