# Amp's orb provider, patched at build time. The provider has no settings for these, so the build
# replaces six exact strings in its bundled main.js and fails unless each occurs exactly once.
# orbs.nix mounts the result over the original in the provider container. What each patch is for:
# docs/reference.md, "Memory snapshots", "Sizing" and "Running out of memory".
{ lib, pkgs, image, fail }:
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
  earlyoom = ''
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
    # Worker pods get the orb's memory plus 128 MiB instead of plus 1 GiB, as their limit and as
    # their request (memoryRequestGi, which is memoryGi unless an orb type sets it lower).
    [ "`\${i.memoryGi+1}Gi`" "`\${i.memoryGi*1024+128}Mi`" ]
    [ "`\${i.memoryRequestGi+1}Gi`" "`\${i.memoryRequestGi*1024+128}Mi`" ]
    # Worker pods request the orb's whole CPU, its limit, instead of 1 CPU: compilers and browsers
    # keep orbs busy, and a node that admits more orb CPU than it has slows every orb down.
    [ ''requests:{cpu:"1",memory:e}'' ''requests:{cpu:String(i.cpu),memory:e}'' ]
    # Orbs start earlyoom, then orbd.
    [ ''command:["/opt/orbd/orbd"]'' "command:${builtins.toJSON [ "/bin/sh" "-c" earlyoom ]}" ]
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
