# The orbs: Amp's orb-provider chart, rendered at build time and shrunk for a small K3s cluster.
# nixos.nix hands the result to K3s as an auto-deploying manifest. What the overlay below changes
# and why: docs/reference.md, "What the overlay changes".
#
# Each patch names the resource, container, volume or argument it changes and fails the build when
# a new chart renamed or removed it, so a chart upgrade cannot drop a patch silently.
{ lib, pkgs, cfg }:
let
  version = "0.20261118.1813"; # the chart the overlay is checked against

  chart = pkgs.runCommand "orb-provider-chart-${version}.tgz" {
    nativeBuildInputs = [ pkgs.kubernetes-helm ];
    outputHashMode = "flat";
    outputHash = "sha256-cEpxtyUVoj7s0b5lzRupo8fkTPfs7JeB98737vbjMcA=";
    SSL_CERT_FILE = "${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt";
  } ''
    export HOME=$TMPDIR
    mkdir $TMPDIR/chart
    helm pull oci://us-central1-docker.pkg.dev/amp-prod-0/orb-provider/chart --version ${version} -d $TMPDIR/chart
    mv $TMPDIR/chart/*.tgz $out
  '';

  values = {
    cloud = "eks"; # EKS mode: S3 storage and the podcert-agent sidecar, so K3s needs no beta feature gates
    snapshots = {
      location = "gs://amp-orbs/orbs/"; # the chart writes gs:// on every backend; here it is the bucket on the in-cluster S3 gateway
      eks = {
        region = "us-east-1";
        ateletRoleArn = "arn:aws:iam::000000000000:role/unused"; # required by the chart, unused on K3s
      };
    };
    workers = {
      architecture = "amd64";
      # Off: the provider's fill counts no init-container sidecars, so on a full node it keeps
      # adding worker pods that can never schedule.
      autoFill = false;
      # The Amp-hosted a1.* sizes. Names must match the orb types on the provider in Amp. A worker
      # reserves memoryGi + 128 MiB and its whole CPU. One warm `small` worker, so a spawn of the
      # default type skips starting a worker pod; it holds its CPU and memory even while idle.
      types = [
        { name = "tiny"; cpu = 1; memoryGi = 2; min = 0; warm = 0; }
        { name = "small"; cpu = 2; memoryGi = 4; min = 0; warm = 1; }
        { name = "medium"; cpu = 4; memoryGi = 8; min = 0; warm = 0; }
        { name = "large"; cpu = 8; memoryGi = 16; min = 0; warm = 0; }
        { name = "xxlarge"; cpu = 16; memoryGi = 32; min = 0; warm = 0; }
      ];
      default = "small";
    };
  };

  # The chart's manifests as one JSON list, read back into Nix below.
  rendered = pkgs.runCommand "orb-provider-${version}.json" {
    nativeBuildInputs = [ pkgs.kubernetes-helm pkgs.yq-go ];
    values = builtins.toJSON values;
    passAsFile = [ "values" ];
  } ''
    export HOME=$TMPDIR
    helm template orb-provider ${chart} --namespace amp-orbs --values $valuesPath |
      yq eval-all -o=json -I=0 '[.] | map(select(. != null))' > $out
  '';

  fail = msg: throw "amp-orbs: ${msg}, in chart ${version}. Check orbs.nix against the chart.";

  # f applied to the value at path, which must exist.
  at = path: f: x:
    if path == [ ] then f x
    else
      let k = builtins.head path; in
      if builtins.isAttrs x && x ? ${k} then x // { ${k} = at (builtins.tail path) f x.${k}; }
      else fail "no ${k} where a patch expects it";

  # f applied to the one item of a list that matches, described by what.
  onlyOne = what: pred: f: list:
    let n = lib.count pred list; in
    if n != 1 then fail "${toString n} ${what}, expected 1"
    else map (x: if pred x then f x else x) list;
  # The list without its one item that matches.
  removeOne = what: pred: list:
    let rest = builtins.filter (x: !pred x) list; in
    if builtins.length rest + 1 != builtins.length list then fail "no ${what} to remove" else rest;

  named = name: onlyOne "items named ${name}" (x: x.name or null == name);
  withoutNamed = name: removeOne name (x: x.name or null == name);
  withoutArg = arg: removeOne "argument ${arg}" (x: x == arg);

  # f applied to the one resource of this kind in namespace/name.
  resource = kind: ns: name: f: onlyOne "${kind} ${ns}/${name}"
    (r: r.kind == kind && r.metadata.namespace or null == ns && r.metadata.name == name) (r: lib.pipe r f);

  pod = f: at [ "spec" "template" "spec" ] f;
  container = name: f: pod (at [ "containers" ] (named name f));
  initContainer = name: f: pod (at [ "initContainers" ] (named name f));
  # Merges into a container's requests and limits, as a strategic merge patch does.
  resources = r: c: c // { resources = lib.recursiveUpdate (c.resources or { }) r; };
  cpu = v: resources { requests.cpu = v; };
  addEnv = env: c: c // { env = (c.env or [ ]) ++ env; };

  s3 = name: key: { inherit name; valueFrom.secretKeyRef = { name = "orb-snapshots-s3"; inherit key; }; };
  # Snapshots go to the in-cluster S3 gateway (versitygw.nix) instead of AWS S3.
  toGateway = addEnv [
    { name = "AWS_ENDPOINT_URL"; value = "http://versitygw.ate-system.svc:7070"; }
    { name = "AWS_S3_USE_PATH_STYLE"; value = "true"; }
    (s3 "AWS_ACCESS_KEY_ID" "AWS_ACCESS_KEY_ID")
    (s3 "AWS_SECRET_ACCESS_KEY" "AWS_SECRET_ACCESS_KEY")
  ];

  chartResources = builtins.fromJSON (builtins.readFile rendered);

  # Helm hooks become plain resources: K3s applies everything at once. Bootstrap runs on every
  # install and upgrade (templates/substrate/bootstrap.yaml), and Kubernetes refuses changes to a
  # finished Job, so its Job is named after the hook resources as deployed: a change to any of
  # them runs a new Job, and K3s deletes the old one.
  isHook = r: (r.metadata.annotations or { }) ? "helm.sh/hook";
  stripHook = r:
    let annotations = lib.filterAttrs (k: _: !lib.hasPrefix "helm.sh/hook" k) r.metadata.annotations; in
    r // { metadata = builtins.removeAttrs r.metadata [ "annotations" ] // lib.optionalAttrs (annotations != { }) { inherit annotations; }; };
  suffix = builtins.substring 0 8 (builtins.hashString "sha256"
    (builtins.toJSON (map stripHook (builtins.filter isHook chartResources))));
  unhook = r:
    if !isHook r then r
    else if r.kind == "Job" then lib.recursiveUpdate (stripHook r) { metadata.name = "${r.metadata.name}-${suffix}"; }
    else stripHook r;

  # The chart leaves these to bootstrap, which runs in amp-orbs; K3s creates them first instead.
  # K3s deletes what disappears from its manifest: removing one here deletes the namespace and
  # everything in it.
  namespaceNames = [ "amp-orbs" "ate-system" "otel-system" "podcertificate-controller-system" ];
  namespaces = map (name: { apiVersion = "v1"; kind = "Namespace"; metadata = { inherit name; }; }) namespaceNames;

  providerImage = (builtins.head (builtins.filter (c: c.name == "provider")
    (builtins.head (builtins.filter (r: r.kind == "Deployment" && r.metadata.name == "amp-orb-provider") chartResources))
      .spec.template.spec.initContainers)).image;
  providerJs = import ./provider.nix { inherit lib pkgs fail; image = providerImage; };

  patches = [
    (resource "Deployment" "ate-system" "ate-api-server" [
      (at [ "spec" "replicas" ] (_: 1))
      # These containers request no CPU, so when busy orbs fill the node's CPU they get almost
      # none of it, and spawns, the API and orbs' egress time out. Requests give them a share
      # (350m in total, with the four below).
      (container "ate-api-server" (cpu "100m"))
      (initContainer "objectstore-plugin" toGateway)
    ])
    (resource "Deployment" "ate-system" "ate-idp-server" [
      (at [ "spec" "replicas" ] (_: 1))
      (container "ate-idp-server" (cpu "25m"))
    ])
    (resource "Deployment" "ate-system" "ate-controller" [ (container "ate-controller" (cpu "25m")) ])
    (resource "Deployment" "ate-system" "atenet-router" [
      (container "atenet-router" (cpu "50m"))
      (container "envoy" (cpu "50m"))
    ])
    (resource "Deployment" "ate-system" "atenet-egress" [
      (container "envoy" (cpu "50m"))
      (container "ext-proc" (cpu "50m"))
    ])

    (resource "StatefulSet" "ate-system" "postgres" [
      (at [ "spec" "volumeClaimTemplates" ] (onlyOne "volume claim templates named data" (t: t.metadata.name == "data") (at [ "spec" "resources" "requests" "storage" ] (_: "5Gi"))))
      (container "postgres" (resources {
        requests = { cpu = "250m"; memory = "512Mi"; };
        limits = { cpu = "2"; memory = "1Gi"; };
      }))
    ])

    # atelet: K3s nodes have no EKS image credential provider, so drop its args and host mounts
    # (as Substrate's kind overlay does) and pull the public images anonymously. Then the snapshot
    # upload limit and the local copy's lifetime (see docs/reference.md, Snapshot timing). The
    # objectstore plugin compresses uploads and decompresses downloads, so it gets a CPU share for
    # busy nodes.
    (resource "DaemonSet" "ate-system" "atelet" [
      (initContainer "objectstore-plugin" (c:
        if c.resources.requests.cpu or null != "50m" then fail "objectstore-plugin requests ${c.resources.requests.cpu or "no"} CPU, expected 50m"
        else lib.pipe c [
          (cpu "100m")
          # The plugin gives up on a snapshot download after the AWS SDK's default 3 attempts
          # (about 6 s), and a failed restore marks the orb crashed, which the provider then
          # deletes with its snapshots. 20 attempts, backing off up to 20 s each, outlast a
          # gateway restart.
          (addEnv [{ name = "AWS_MAX_ATTEMPTS"; value = "20"; }])
          toGateway
        ]))
      (container "atelet" (c: c // {
        args = withoutArg "--image-credential-provider-config=/run/image-credential-provider/config.yaml"
          (withoutArg "--image-credential-provider-bin-dir=/run/image-credential-provider/bin" c.args) ++ [
          "--snapshot-upload-timeout=3m"
          "--snapshot-upload-est-throughput-mib=5"
          # One upload at a time: uploads share the plugin's 512 MiB buffer budget, and a second
          # one waits there on the clock, behind the first one's memory image, until its deadline passes.
          "--snapshot-upload-workers=1"
          "--snapshot-detach-delay=24h"
        ];
        volumeMounts = withoutNamed "image-credential-provider-config" (withoutNamed "image-credential-provider-bin" c.volumeMounts);
      }))
      (pod (p: p // { volumes = withoutNamed "image-credential-provider-config" (withoutNamed "image-credential-provider-bin" p.volumes); }))
    ])

    # The provider runs the patched main.js (provider.nix), mounted from the server's Nix store; it
    # runs only on the server (below). Its probes start `node` to fetch from loopback, which takes
    # over the chart's default 1 s when orbs saturate the CPU; the kubelet then restarts a provider
    # that is still serving, so they get 10 s.
    (resource "Deployment" "amp-orbs" "amp-orb-provider" [
      (initContainer "provider" (c: lib.pipe c [
        (at [ "volumeMounts" ] (m: m ++ [{ name = "provider-main"; mountPath = "/opt/amp-orb-provider/main.js"; readOnly = true; }]))
        (at [ "startupProbe" ] (p: p // { timeoutSeconds = 10; }))
        (at [ "livenessProbe" ] (p: p // { timeoutSeconds = 10; }))
        (at [ "readinessProbe" ] (p: p // { timeoutSeconds = 10; }))
      ]))
      (pod (at [ "volumes" ] (v: v ++ [{ name = "provider-main"; hostPath = { path = "${providerJs}"; type = "File"; }; }])))
    ])
  ];

  # The shared services run on the server: the burst machines get shut down, and Postgres keeps
  # its local volume on the node it first runs on. K3s labels its servers with this.
  onServer = r:
    if builtins.elem r.kind [ "Deployment" "StatefulSet" ] && builtins.elem (r.metadata.namespace or null) namespaceNames
    then pod (p:
      if p ? affinity then fail "${r.kind} ${r.metadata.name} already has an affinity"
      else p // {
        affinity.nodeAffinity.requiredDuringSchedulingIgnoredDuringExecution.nodeSelectorTerms = [{
          matchExpressions = [{ key = "node-role.kubernetes.io/control-plane"; operator = "In"; values = [ "true" ]; }];
        }];
      }) r
    else r;
in
namespaces ++ map onServer (lib.pipe (map unhook chartResources ++ import ./versitygw.nix { inherit s3; }) patches)
