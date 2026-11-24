# Snapshots go to this in-cluster S3 gateway instead of AWS S3: Versity S3 Gateway with its POSIX
# backend, which stores each object as a plain file in a directory on the server's disk
# (docs/reference.md, Snapshot store). Lives in ate-system so the runtime reaches it.
{ s3 }:
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
          containers = [{
            name = "versitygw";
            inherit image;
            command = [ "sh" "-ec" ''
              # The POSIX backend serves each top-level directory as a bucket, and keeps object
              # metadata in extended attributes. The chart stores snapshots under
              # gs://amp-orbs/orbs/, so the amp-orbs directory is the whole bucket setup.
              mkdir -p /data/amp-orbs
              exec versitygw --port :7070 posix /data
            '' ];
            ports = [{ containerPort = 7070; name = "api"; }];
            env = [
              (s3 "ROOT_ACCESS_KEY_ID" "AWS_ACCESS_KEY_ID")
              (s3 "ROOT_SECRET_ACCESS_KEY" "AWS_SECRET_ACCESS_KEY")
            ];
            readinessProbe = { tcpSocket.port = "api"; periodSeconds = 5; };
            # A real CPU request: on a node busy with orbs, at 50m it took minutes to assemble
            # each uploaded memory image, and uploads ran past their deadline.
            resources = {
              requests = { cpu = "250m"; memory = "64Mi"; };
              limits.memory = "1Gi";
            };
            volumeMounts = [{ name = "data"; mountPath = "/data"; }];
          }];
          volumes = [
            # Paused orbs, on the server's disk (orbs.nix pins this Deployment to the server).
            { name = "data"; hostPath = { path = "/var/lib/amp-orbs/snapshots"; type = "DirectoryOrCreate"; }; }
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
