# Amp's orb provider, patched at build time. The provider has no settings for these, so the build
# replaces eight exact strings in its bundled main.js and fails unless each occurs exactly once.
# orbs.nix mounts the result over the original in the provider container. What each patch is for:
# docs/reference.md, "Memory snapshots", "Sizing" and "Running out of memory".
{ lib, pkgs, image, fail, kubernetesVersion, appsDomain }:
let
  # main.js from the provider image the chart names, pinned by hash: a new chart's provider
  # fails here first, with the hash to put below once the patches are checked against it. The
  # name carries the image, since a fixed-output path depends only on its name and hash: with a
  # fixed name, a machine that has the old path would never fetch a new image's main.js.
  original = pkgs.runCommand "amp-orb-provider-main-${builtins.substring 0 16 (builtins.hashString "sha256" image)}.js" {
    nativeBuildInputs = [ pkgs.crane pkgs.gnutar ];
    outputHashMode = "flat";
    outputHash = "sha256-EUIXNfbT0lDzKeRPQcVxsTxEcA+TcY6EPNSC21UkfdU=";
    SSL_CERT_FILE = "${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt";
  } ''
    export HOME=$TMPDIR
    crane export ${image} - | tar -xO opt/amp-orb-provider/main.js > $out
  '';

  # Runs before orbd in every new orb, then hands PID 1 to orbd. gVisor has no OOM killer, so
  # earlyoom stops the largest process while 10% of the orb's memory is still free; every
  # oom_score is 0 under gVisor, so --avoid keeps Amp's and Docker's daemons out of its choice.
  # The orb image has the package available but not installed; the loops retry until apt works
  # and restart earlyoom if it exits. A woken orb keeps both running from its memory snapshot.
  # It also installs the kubectl of the cluster's Kubernetes version (deploying-k3s-apps), checked
  # against the checksum published next to it, retrying until the download works.
  # Temporary workaround, to be removed with github-ssh in platform/traefik.yaml once the projects
  # that still clone over SSH use HTTPS: SSH to github.com goes through Traefik wrapped in TLS, since the
  # egress gateway refuses SSH. GitHub's host keys (api.github.com/meta) go in the user's
  # known_hosts as well as the global one, so a setup script that runs ssh-keyscan only for an
  # unknown github.com, which cannot connect through the gateway, skips it.
  sshHost = "github-ssh.${appsDomain}";
  githubHostKeys = ''
    github.com ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOMqqnkVzrm0SdG6UOoqKLsabgH5C9okWi0dh2l9GKJl
    github.com ecdsa-sha2-nistp256 AAAAE2VjZHNhLXNoYTItbmlzdHAyNTYAAAAIbmlzdHAyNTYAAABBBEmKSENjQEezOmxkZMy7opKgwFB9nkt5YRrYMjNuG5N87uRgg6CLrbo5wAdT/y6v0mKV0U2w0WZ2YB/++Tpockg=
    github.com ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABgQCj7ndNxQowgcQnjshcLrqPEiiphnt+VTTvDP6mHBL9j1aNUkY4Ue1gvwnGLVlOhGeYrnZaMgRK6+PKCUXaDbC7qtbW8gIkhL7aGCsOr/C56SJMy/BCZfxd1nWzAOxSDPgVsmerOBYfNqltV9/hWCqBywINIR+5dIg6JTJ72pcEpEjcYgXkE2YEFXV1JHnsKgbLWNlhScqb2UmyRkQyytRLtL+38TGxkxCflmO+5Z8CSSNY7GidjMIZ7Q4zMjA2n1nGrlTDkzwDCsw+wqFPGQA179cnfGWOWRVruj16z6XyvxvjJwbz0wQZ75XK5tKSb7FNyeIEs4TT4jk+S4dhPeAUC5y+bDYirYgM4GC7uEnztnZyaVWQ7B381AK4Qdrwt51ZqExKbQpTUNn+EjqoTwvqNj4kqx5QUCI0ThS/YkOxJCXmPUWZbhjpCg56i+2aB6CmK2JGhn57K5mj0MNdBXA4/WnwH6XoPWJzK5Nyu2zB3nAZp+S5hpQs+p1vN1/wsjk=
  '';
  sshConfig = ''
    Host github.com
      ProxyCommand openssl s_client -quiet -verify_return_error -verify_hostname ${sshHost} -connect ${sshHost}:443 -servername ${sshHost}
  '';
  start = ''
    mkdir -p /etc/ssh/ssh_config.d
    printf '%s' ${lib.escapeShellArg sshConfig} > /etc/ssh/ssh_config.d/github.conf
    printf '%s' ${lib.escapeShellArg githubHostKeys} >> /etc/ssh/ssh_known_hosts
    install -d -m 700 -o user -g user /home/user/.ssh &&
      printf '%s' ${lib.escapeShellArg githubHostKeys} >> /home/user/.ssh/known_hosts &&
      chown user:user /home/user/.ssh/known_hosts && chmod 600 /home/user/.ssh/known_hosts
    (
      u=https://dl.k8s.io/release/v${lib.head (lib.splitString "+" kubernetesVersion)}/bin/linux/amd64/kubectl
      until /usr/local/bin/kubectl version --client >/dev/null 2>&1; do
        { curl -fsSLo /tmp/kubectl "$u" && echo "$(curl -fsSL "$u.sha256")  /tmp/kubectl" | sha256sum -c &&
          install -m 755 /tmp/kubectl /usr/local/bin/kubectl; } || sleep 10
      done
      rm -f /tmp/kubectl
    ) >>/var/log/kubectl-install.log 2>&1 </dev/null &
    (
      while ! command -v earlyoom >/dev/null; do
        DEBIAN_FRONTEND=noninteractive apt-get install -y -q -o DPkg::Lock::Timeout=60 earlyoom ||
          { apt-get update -q && DEBIAN_FRONTEND=noninteractive apt-get install -y -q -o DPkg::Lock::Timeout=60 earlyoom; } ||
          sleep 10
      done
      while :; do earlyoom -m 10 -r 3600 --avoid '^(orbd|amp|dockerd|containerd)$'; sleep 5; done
    ) >>/var/log/earlyoom.log 2>&1 </dev/null &
    exec /opt/orbd/orbd
  '';

  patches = [
    # Pauses save process memory too, so processes keep running after a resume.
    [ ''preferredFidelity:"SNAPSHOT_FIDELITY_ROOTFS"'' ''preferredFidelity:"SNAPSHOT_FIDELITY_MEMORY"'' ]
    # A pause returns once the snapshot is on the node; the upload continues in the background.
    [ ''{durable:"DURABILITY_MODE_SYNCHRONOUS",'' ''{durable:"DURABILITY_MODE_ASYNCHRONOUS",'' ]
    # Worker pods request the orb's memory plus 128 MiB instead of plus 1 GiB (memoryRequestGi,
    # which is memoryGi unless an orb type sets it lower), and get 128 MiB more as their limit:
    # the kubelet's LimitedSwap gives no swap to a container whose limit equals its request.
    [ "`\${i.memoryGi+1}Gi`" "`\${i.memoryGi*1024+256}Mi`" ]
    [ "`\${i.memoryRequestGi+1}Gi`" "`\${i.memoryRequestGi*1024+128}Mi`" ]
    # Worker pods request the orb's whole CPU, its limit, instead of 1 CPU: compilers and browsers
    # keep orbs busy, and a node that admits more orb CPU than it has slows every orb down.
    [ ''requests:{cpu:"1",memory:e}'' ''requests:{cpu:String(i.cpu),memory:e}'' ]
    # Worker pods prefer a machine labelled amp-orbs/prefer-orbs=true (preferOrbs in nixos.nix),
    # a fast burst machine, whenever it is up and has room.
    [ "template:{nodeSelector:r,tolerations:n," ''template:{nodeSelector:r,tolerations:n,nodeAffinity:{preferredDuringSchedulingIgnoredDuringExecution:[{weight:100,preference:{matchExpressions:[{key:"amp-orbs/prefer-orbs",operator:"In",values:["true"]}]}}]},'' ]
    # The pool shrinks to its warm workers after 1 minute oversized instead of 10, so idle
    # workers stop holding their requests and a pending worker that is no longer needed goes.
    [ ",aut=6e5," ",aut=6e4," ]
    # Orbs start earlyoom, install kubectl and set up SSH to GitHub, then start orbd.
    [ ''command:["/opt/orbd/orbd"]'' "command:${builtins.toJSON [ "/bin/sh" "-c" start ]}" ]
  ];

  occurrences = s: js: (builtins.length (builtins.split (lib.escapeRegex s) js) - 1) / 2;
  patch = js: p:
    let
      from = builtins.elemAt p 0;
      n = occurrences from js;
    in
    if n != 1 then fail "the provider has ${toString n} occurrences of ${from}, expected 1"
    else builtins.replaceStrings [ from ] [ (builtins.elemAt p 1) ] js;
in
pkgs.writeText "amp-orb-provider-main.js" (builtins.foldl' patch (builtins.readFile original) patches)
