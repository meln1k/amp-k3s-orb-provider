#!/bin/sh
# Helm post-renderer: helm pipes the rendered chart in, kustomize applies the K3s overlay.
set -eu
cd "$(dirname "$0")"
cat > all.yaml
exec kubectl kustomize .
