# Apps' SQLite backups (Litestream): a second Versity S3 gateway, separate from the snapshot
# gateway (versitygw.nix), whose POSIX backend is a gocryptfs mount on an NFS export of a NAS, so
# the NAS only holds encrypted file names and contents (docs/reference.md, Backups). Apps reach it
# at http://versitygw.backups.svc:7070 with the credentials in the Secret apps/litestream; nothing
# else does. It runs on the server, next to the other shared services.
{ nas }:
let
  image = "versity/versitygw:v1.11.0@sha256:8319a530d08d537426e2f855bae5280709795dc73a3f0c347973ef915d6343c5";
  s3 = name: key: { inherit name; valueFrom.secretKeyRef = { name = "versitygw-s3"; inherit key; }; };
in
[
  {
    apiVersion = "v1";
    kind = "Namespace";
    metadata.name = "backups";
  }
  {
    apiVersion = "v1";
    kind = "Service";
    metadata = { name = "versitygw"; namespace = "backups"; };
    spec = {
      selector.app = "versitygw";
      ports = [{ name = "api"; port = 7070; targetPort = 7070; }];
    };
  }
  {
    apiVersion = "apps/v1";
    kind = "Deployment";
    metadata = { name = "versitygw"; namespace = "backups"; };
    spec = {
      replicas = 1;
      strategy.type = "Recreate";
      selector.matchLabels.app = "versitygw";
      template = {
        metadata.labels.app = "versitygw";
        spec = {
          nodeSelector."node-role.kubernetes.io/control-plane" = "true";
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
              # An empty directory gets a new gocryptfs master key, stored in it encrypted with
              # litestream.key (the server's /var/lib/amp-orbs; keep a copy off the machine).
              [ -e /cipher/gocryptfs.conf ] || /tools/gocryptfs -q -init -passfile /key/litestream.key /cipher
              mkdir -p /plain
              /tools/gocryptfs -q -passfile /key/litestream.key /cipher /plain
              # The POSIX backend serves each top-level directory as a bucket.
              mkdir -p /plain/data/litestream /plain/meta
              exec versitygw --port :7070 posix /plain/data
            '' ];
            ports = [{ containerPort = 7070; name = "api"; }];
            env = [
              (s3 "ROOT_ACCESS_KEY_ID" "AWS_ACCESS_KEY_ID")
              (s3 "ROOT_SECRET_ACCESS_KEY" "AWS_SECRET_ACCESS_KEY")
              # Object metadata goes in files under meta/ next to data/, since NFS has no
              # extended attributes; Versity calls this mode experimental.
              { name = "VGW_META_SIDECAR"; value = "/plain/meta"; }
            ];
            readinessProbe = { tcpSocket.port = "api"; periodSeconds = 5; };
            # Restart the container if gocryptfs exits, which leaves /plain unreadable. The NFS
            # mount is hard, so while the NAS restarts the check hangs and requests wait;
            # restarting the gateway then would drop them, so it has to fail for 5 minutes first.
            livenessProbe = {
              exec.command = [ "test" "-d" "/plain/data/litestream" ];
              periodSeconds = 10;
              timeoutSeconds = 10;
              failureThreshold = 30;
            };
            resources = {
              requests = { cpu = "50m"; memory = "64Mi"; };
              limits.memory = "512Mi";
            };
            volumeMounts = [
              { name = "data"; mountPath = "/cipher"; subPath = "litestream"; }
              { name = "tools"; mountPath = "/tools"; readOnly = true; }
              { name = "key"; mountPath = "/key"; readOnly = true; }
            ];
          }];
          volumes = [
            { name = "data"; nfs = { inherit (nas) server path; }; }
            { name = "tools"; emptyDir = { }; }
            { name = "key"; secret = { secretName = "litestream-key"; defaultMode = 256; }; } # 0400
          ];
        };
      };
    };
  }
  # Only apps reach the gateway.
  {
    apiVersion = "networking.k8s.io/v1";
    kind = "NetworkPolicy";
    metadata = { name = "from-apps"; namespace = "backups"; };
    spec = {
      podSelector = { };
      policyTypes = [ "Ingress" ];
      ingress = [{
        from = [{ namespaceSelector.matchLabels."kubernetes.io/metadata.name" = "apps"; }];
        ports = [{ protocol = "TCP"; port = 7070; }];
      }];
    };
  }
]
