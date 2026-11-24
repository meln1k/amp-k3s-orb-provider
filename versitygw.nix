# Snapshots go to this in-cluster S3 gateway instead of AWS S3: Versity S3 Gateway with its POSIX
# backend, which stores each object as a file. It writes them through gocryptfs, so the NAS only
# holds encrypted files and names (docs/reference.md, Snapshot encryption). Lives in ate-system so
# the runtime reaches it.
{ nas, s3 }:
let
  image = "versity/versitygw:v1.11.0@sha256:8319a530d08d537426e2f855bae5280709795dc73a3f0c347973ef915d6343c5";
in
[
  {
    apiVersion = "v1";
    kind = "Service";
    metadata = { name = "versitygw"; namespace = "ate-system"; };
    spec = {
      selector.app = "versitygw";
      ports = [{ name = "api"; port = 7070; targetPort = 7070; }];
    };
  }
  {
    apiVersion = "apps/v1";
    kind = "Deployment";
    metadata = { name = "versitygw"; namespace = "ate-system"; };
    spec = {
      replicas = 1;
      strategy.type = "Recreate";
      selector.matchLabels.app = "versitygw";
      template = {
        metadata.labels.app = "versitygw";
        spec = {
          initContainers = [{
            # gocryptfs's static binary from its signed GitHub release, checked against its SHA-256.
            name = "get-gocryptfs";
            inherit image;
            command = [ "sh" "-ec" ''
              wget -qO /tmp/g.tgz https://github.com/rfjakob/gocryptfs/releases/download/v2.7.0/gocryptfs_v2.7.0_linux-static_amd64.tar.gz
              echo "3e2e2a5270921e01bfbb46ebc39b614d0146d6961a28de4ba9cc5d43534b8dcf  /tmp/g.tgz" | sha256sum -c -
              tar -xzf /tmp/g.tgz -C /tools gocryptfs
            '' ];
            volumeMounts = [{ name = "tools"; mountPath = "/tools"; }];
          }];
          containers = [{
            name = "versitygw";
            inherit image;
            # Mounting a FUSE filesystem needs a privileged container.
            securityContext.privileged = true;
            command = [ "sh" "-ec" ''
              # An empty volume gets a new gocryptfs master key, stored on it encrypted with snapshots.key.
              [ -e /cipher/gocryptfs.conf ] || /tools/gocryptfs -q -init -passfile /key/snapshots.key /cipher
              mkdir -p /plain
              /tools/gocryptfs -q -passfile /key/snapshots.key /cipher /plain
              # The POSIX backend serves each top-level directory as a bucket. The chart stores
              # snapshots under gs://amp-orbs/orbs/, so the amp-orbs directory is the whole bucket setup.
              mkdir -p /plain/data/amp-orbs /plain/meta
              exec versitygw --port :7070 posix /plain/data
            '' ];
            ports = [{ containerPort = 7070; name = "api"; }];
            env = [
              (s3 "ROOT_ACCESS_KEY_ID" "AWS_ACCESS_KEY_ID")
              (s3 "ROOT_SECRET_ACCESS_KEY" "AWS_SECRET_ACCESS_KEY")
              # Object metadata goes in files under meta/ next to data/, so this also works on
              # NFSv3, which has no extended attributes; Versity calls this mode experimental.
              { name = "VGW_META_SIDECAR"; value = "/plain/meta"; }
            ];
            readinessProbe = { tcpSocket.port = "api"; periodSeconds = 5; };
            # Restart the container if gocryptfs exits, which leaves /plain unreadable. The NFS
            # mount is hard, so while the NAS restarts the check hangs and requests wait;
            # restarting the gateway then would drop them, so it has to fail for 5 minutes first.
            livenessProbe = {
              exec.command = [ "test" "-d" "/plain/data/amp-orbs" ];
              periodSeconds = 10;
              timeoutSeconds = 10;
              failureThreshold = 30;
            };
            # A real CPU request: on a node busy with orbs, at 50m it took minutes to assemble
            # each uploaded memory image, and uploads ran past their deadline.
            resources = {
              requests = { cpu = "250m"; memory = "64Mi"; };
              limits.memory = "1Gi";
            };
            volumeMounts = [
              { name = "data"; mountPath = "/cipher"; subPath = "encrypted"; }
              { name = "tools"; mountPath = "/tools"; readOnly = true; }
              { name = "key"; mountPath = "/key"; readOnly = true; }
            ];
          }];
          volumes = [
            # The gateway stores paused orbs, encrypted, in encrypted/ on the NAS's export.
            { name = "data"; nfs = { inherit (nas) server path; }; }
            { name = "tools"; emptyDir = { }; }
            { name = "key"; secret = { secretName = "orb-snapshots-key"; defaultMode = 256; }; } # 0400
          ];
        };
      };
    };
  }
  # ate-system denies ingress by default; let only the runtime in.
  {
    apiVersion = "networking.k8s.io/v1";
    kind = "NetworkPolicy";
    metadata = { name = "versitygw"; namespace = "ate-system"; };
    spec = {
      podSelector.matchLabels.app = "versitygw";
      policyTypes = [ "Ingress" ];
      ingress = [{
        from = [{ podSelector.matchExpressions = [{ key = "app"; operator = "In"; values = [ "ate-api-server" "atelet" ]; }]; }];
        ports = [{ protocol = "TCP"; port = "api"; }];
      }];
    };
  }
]
