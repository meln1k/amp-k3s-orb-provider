# NixOS module for every machine of the cluster: K3s, the orbs, and the apps platform. The
# server deploys the cluster's resources as K3s auto-deploying manifests, so `nixos-rebuild switch`
# installs and upgrades everything. Import it from this repo's flake as nixosModules.default; see
# the README.
{ config, lib, pkgs, ... }:
let
  cfg = config.services.amp-orbs;
  server = cfg.role == "server";
  k3s = config.services.k3s.package;
  # The server's credentials and generated keys, root-only (README, step 2).
  stateDir = "/var/lib/amp-orbs";

  registries = pkgs.writeText "registries.yaml" ''
    # The apps platform (platform/registry.yaml): app images from the in-cluster registry's fixed
    # ClusterIP.
    mirrors:
      "registry.registry.svc:8080":
        endpoint: ["http://10.43.0.50:8080"]
  '';

  # The apps platform's manifests name apps.example.com where the apps' domain goes, and
  # 192.0.2.1/32 where the server's address goes.
  platform = file: pkgs.writeText (baseNameOf file)
    (builtins.replaceStrings [ "apps.example.com" "192.0.2.1/32" ] [ cfg.appsDomain "${cfg.nodeIP}/32" ]
      (builtins.readFile file));
  # Each becomes the K3s manifest amp-apps-<name>.yaml. The names stay fixed: tmpfiles never
  # removes the link of a manifest that is renamed or dropped (ExecStartPre below does).
  # coredns-custom.yaml is applied by amp-orbs-secrets instead, which restarts CoreDNS after it.
  platformFiles = {
    cert-manager = ./platform/cert-manager.yaml;
    tailscale = ./platform/tailscale.yaml;
    traefik = ./platform/traefik.yaml;
    apps = ./platform/apps.yaml;
    tasks = ./platform/tasks.yaml;
    registry = ./platform/registry.yaml;
    # It needs cert-manager's CRDs; K3s retries it every 15 s until cert-manager is up.
    certs-letsencrypt = ./platform/certs/letsencrypt.yaml;
  };
  manifestDir = "/var/lib/rancher/k3s/server/manifests";

  # Creates the Secrets the manifests refer to from the files in stateDir, so no secret enters
  # the Nix store. kubectl reads each value from its file, never from its arguments.
  secrets = pkgs.writeShellScript "amp-orbs-secrets" ''
    set -euo pipefail
    export KUBECONFIG=/etc/rancher/k3s/k3s.yaml PATH=${lib.makeBinPath [ k3s pkgs.openssl pkgs.coreutils pkgs.gnugrep ]}
    umask 077
    mkdir -p ${stateDir}
    cd ${stateDir}
    for f in orb-provider-token cloudflare-api-token ts-oauth-client-id ts-oauth-client-secret; do
      [ -s "$f" ] || { echo "missing ${stateDir}/$f (README, step 2)" >&2; exit 1; }
    done
    # Generated once: the snapshot gateway's credentials.
    [ -e s3.env ] || printf 'AWS_ACCESS_KEY_ID=%s\nAWS_SECRET_ACCESS_KEY=%s\n' \
      "$(openssl rand -hex 10)" "$(openssl rand -hex 24)" > s3.env

    until kubectl get --raw /readyz >/dev/null 2>&1; do sleep 5; done
    # secret <namespace> <name> <kubectl create secret generic arguments>...
    secret() {
      local ns=$1 name=$2; shift 2
      kubectl get namespace "$ns" >/dev/null 2>&1 || kubectl create namespace "$ns" >/dev/null ||
        kubectl get namespace "$ns" >/dev/null # K3s created it in between
      kubectl -n "$ns" create secret generic "$name" "$@" --dry-run=client -o yaml | kubectl apply -f -
    }
    secret ate-system orb-snapshots-s3 --from-env-file=s3.env
    secret amp-orbs amp-orb-spawner --from-file=AMP_ORB_PROVIDER_TOKEN=orb-provider-token
    secret tailscale operator-oauth --from-file=client_id=ts-oauth-client-id \
      --from-file=client_secret=ts-oauth-client-secret
    secret cert-manager cloudflare-api-token --from-file=api-token=cloudflare-api-token
    ${lib.optionalString (cfg.backups.nas != null) ''
      # Generated once. Without litestream.key the backups on the NAS cannot be read: keep a copy
      # off this machine (README, step 2).
      [ -e litestream-s3.env ] || printf 'AWS_ACCESS_KEY_ID=%s\nAWS_SECRET_ACCESS_KEY=%s\n' \
        "$(openssl rand -hex 10)" "$(openssl rand -hex 24)" > litestream-s3.env
      [ -e litestream.key ] || openssl rand -base64 32 > litestream.key
      secret backups versitygw-s3 --from-env-file=litestream-s3.env
      secret backups litestream-key --from-file=litestream.key
      secret apps litestream --from-env-file=litestream-s3.env
    ''}

    # CoreDNS reads the custom server blocks only when it starts, so restart it after a change.
    out=$(kubectl apply -f ${platform ./platform/coredns-custom.yaml})
    echo "$out"
    if grep -Eq ' (created|configured)$' <<<"$out"; then
      until kubectl -n kube-system get deploy/coredns >/dev/null 2>&1; do sleep 5; done
      kubectl -n kube-system rollout restart deploy/coredns
    fi
  '';
in
{
  options.services.amp-orbs = {
    enable = lib.mkEnableOption "a K3s node for Amp orbs";
    role = lib.mkOption {
      type = lib.types.enum [ "server" "apps" "burst" ];
      description = ''
        server: the K3s server, with the shared services and orbs. apps: the apps platform and
        the apps, never orbs. burst: orbs only when the other machines are full, and tasks
        (platform/tasks.yaml), never apps; shut it down when you do not need it.
      '';
    };
    nodeIP = lib.mkOption {
      type = lib.types.str;
      example = "192.168.1.10";
      description = ''
        The IPv4 address the other machines reach this one at, on the LAN. Without it, K3s exits
        when the network hands out a new IPv6 prefix.
      '';
    };
    serverAddr = lib.mkOption {
      type = lib.types.str;
      example = "https://192.168.1.10:6443";
      description = "Not on the server: the server's API.";
    };
    tokenFile = lib.mkOption {
      type = lib.types.str;
      example = "/root/k3s-token";
      description = "Not on the server: a copy of the server's /var/lib/rancher/k3s/server/node-token.";
    };
    appsDomain = lib.mkOption {
      type = lib.types.strMatching "([a-z0-9]([a-z0-9-]*[a-z0-9])?\\.)+[a-z]{2,}";
      example = "apps.example.com";
      description = "Server only: the apps' domain, in a zone on Cloudflare.";
    };
    backups.nas = lib.mkOption {
      type = lib.types.nullOr (lib.types.submodule {
        options = {
          server = lib.mkOption { type = lib.types.str; example = "192.168.1.5"; };
          path = lib.mkOption { type = lib.types.str; example = "/var/nfs/shared/backups"; };
        };
      });
      default = null;
      description = ''
        Server only: an NFS export, writable by root from the server, where apps' SQLite backups
        (Litestream) are stored, encrypted (backups.nix). They go in its litestream directory.
        Null: no backup gateway.
      '';
    };
  };

  config = lib.mkIf cfg.enable (lib.mkMerge [
    {
      assertions = [{
        # atelet mounts each orb's rootfs with overlayfs "lowerdir+": 6.7+, or 6.6.23+ (backport).
        assertion = lib.versionAtLeast config.boot.kernelPackages.kernel.version "6.6.23";
        message = "services.amp-orbs needs Linux 6.7+ or 6.6.23+ (overlayfs lowerdir+); set boot.kernelPackages.";
      }];

      boot.kernel.sysctl = {
        # gVisor mirrors every memory mapping of an orb into one host process.
        "vm.max_map_count" = 4194304;
        # Substrate's kind setup enables these for gVisor pod-to-pod loopback networking.
        "net.ipv4.conf.all.proxy_arp" = 1;
        "net.ipv6.conf.all.proxy_ndp" = 1;
        "fs.inotify.max_user_instances" = 8192;
        "fs.inotify.max_user_watches" = 1048576;
      };
      environment.etc."rancher/k3s/registries.yaml".source = registries;
      # K3s reads it only when it starts.
      systemd.services.k3s.restartTriggers = [ registries ];

      services.k3s = {
        enable = true;
        role = if server then "server" else "agent";
        nodeIP = cfg.nodeIP;
        serverAddr = lib.mkIf (!server) cfg.serverAddr;
        tokenFile = lib.mkIf (!server) cfg.tokenFile;
        # K3s sets labels and taints when a node registers. Orbs run only where atelet runs, on
        # nodes with the gvisor label. The apps machine has none and a taint orb workers do not
        # tolerate; the apps platform's namespaces put their pods there (platform/*.yaml). Apps
        # themselves (the apps namespace) also run on the server, which has no taint. Burst
        # machines take orbs only when the others are full, and the tasks namespace's pods, which
        # run nowhere else; they never run apps (no runs-apps label).
        nodeLabel = {
          server = [ "ate.dev/sandboxClass=gvisor" "amp-orbs/runs-apps=true" ];
          apps = [ "amp-orbs/role=apps" "amp-orbs/runs-apps=true" ];
          burst = [ "ate.dev/sandboxClass=gvisor" "amp-orbs/role=burst" ];
        }.${cfg.role};
        nodeTaint = {
          server = [ ];
          apps = [ "amp-orbs/apps=true:NoSchedule" ];
          burst = [ "amp-orbs/burst=true:PreferNoSchedule" ];
        }.${cfg.role};
        # CPU kept out of what pods can request, for K3s itself (API server, kubelet, containerd)
        # and the host. Orbs request their whole CPU, so without it they could book every core.
        # No memory reserved: memory decides how many orbs fit.
        extraKubeletConfig = {
          kubeReserved.cpu = "500m";
          systemReserved.cpu = "500m";
        };
      };

      networking.firewall = {
        # Pods reach the node's own ports (the API, the kubelet) through these.
        trustedInterfaces = [ "cni0" "flannel.1" ];
        # The machines talk to each other on these: the kubelet (the API reaches it for logs and
        # exec) and flannel's VXLAN. The server also opens the API, below.
        allowedTCPPorts = [ 10250 ];
        allowedUDPPorts = [ 8472 ];
      };
    }

    # A burst machine's shutdown waits for its orbs: the kubelet stops the orb workers first, which
    # suspend their orbs, then atelet (a critical pod, 330 s grace), which uploads the snapshots to
    # the server. logind has to allow the kubelet to delay the shutdown that long.
    (lib.mkIf (cfg.role == "burst") {
      services.k3s.gracefulNodeShutdown = {
        enable = true;
        shutdownGracePeriod = "15m";
        shutdownGracePeriodCriticalPods = "330s";
      };
      services.logind.settings.Login.InhibitDelayMaxSec = "15min";
    })

    (lib.mkIf server {
      services.k3s = {
        # The apps platform brings its own Traefik on the tailnet.
        disable = [ "traefik" "servicelb" ];
        manifests = {
          amp-orbs.content = import ./orbs.nix { inherit lib pkgs cfg; kubernetesVersion = k3s.version; };
        } // lib.optionalAttrs (cfg.backups.nas != null) {
          amp-backups.content = import ./backups.nix { inherit (cfg.backups) nas; };
        } // lib.mapAttrs' (name: f: lib.nameValuePair "amp-apps-${name}" { source = platform f; }) platformFiles;
        extraFlags = [
          # The API also accepts the Amp ID tokens orbs mint (platform/amp-auth.yaml).
          "--kube-apiserver-arg=authentication-config=/etc/rancher/k3s/amp-auth.yaml"
          # Namespace annotations put the apps platform's pods on the apps machine
          # (platform/*.yaml). NodeRestriction is K3s's own default, which this flag replaces.
          "--kube-apiserver-arg=enable-admission-plugins=NodeRestriction,PodNodeSelector,PodTolerationRestriction"
        ];
      };
      environment.etc."rancher/k3s/amp-auth.yaml" = {
        source = ./platform/amp-auth.yaml;
        mode = "0600";
      };
      systemd.services.k3s.restartTriggers = [ ./platform/amp-auth.yaml ];
      # The manifests are symlinks that tmpfiles creates only at boot or on a switch, and never
      # removes. Before K3s starts, drop this module's links, so a renamed or dropped manifest
      # leaves no stale or dangling one (a dangling link stops K3s applying any manifest), and
      # create the current ones, also after a reset of /var/lib/rancher.
      systemd.services.k3s.serviceConfig.ExecStartPre = [
        # "-": the directory does not exist before K3s's first start.
        "-${pkgs.findutils}/bin/find ${manifestDir} -maxdepth 1 -name 'amp-*' -type l -delete"
        # Exit 65 is a bad line in any tmpfiles config on the system, even outside the prefix;
        # NixOS's own systemd-tmpfiles-setup tolerates it too. A link it cannot create still fails.
        (pkgs.writeShellScript "amp-orbs-manifests" ''
          ${config.systemd.package}/bin/systemd-tmpfiles --create --prefix=${manifestDir} || [ $? = 65 ]
        '')
      ];
      networking.firewall.allowedTCPPorts = [ 6443 ];
      # The kubelet mounts the NAS for the backup gateway (backups.nix).
      boot.supportedFilesystems = lib.mkIf (cfg.backups.nas != null) [ "nfs" ];

      systemd.tmpfiles.rules = [ "d ${stateDir} 0700 root root -" ];
      systemd.services.amp-orbs-secrets = {
        description = "Secrets for Amp orbs on K3s";
        after = [ "k3s.service" ];
        requires = [ "k3s.service" ];
        wantedBy = [ "multi-user.target" ];
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
          ExecStart = secrets;
          # Its waits for K3s would otherwise hold up nixos-rebuild switch for good.
          TimeoutStartSec = "10min";
        };
      };
    })
  ]);
}
