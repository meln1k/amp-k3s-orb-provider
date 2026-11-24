#!/usr/bin/env bash
# Moves orbs.nix to the newest orb-provider chart (or the version given as $1): sets the version,
# refills the chart's and the provider main.js's hashes, then renders the server's manifest. It
# exits 0 when the chart is current or the new one renders, and non-zero with the build's error
# (a patch that no longer matches, a renamed workload) when it does not. It never commits.
#
# Needs x86_64 Linux, Nix with flakes and network access. Where Nix cannot sandbox (an Amp orb),
# run it with NIX_FLAGS="--option sandbox false".
set -euo pipefail
cd "$(dirname "$0")"
repo=$PWD
nixpkgs=${NIXPKGS:-github:NixOS/nixpkgs/nixos-unstable}
read -ra flags <<<"${NIX_FLAGS:-}"
fake=sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=

current=$(sed -n 's/^  version = "\([^"]*\)";.*/\1/p' orbs.nix)
latest=${1:-$(nix run "${flags[@]}" "$nixpkgs#crane" -- ls us-central1-docker.pkg.dev/amp-prod-0/orb-provider/chart | sort -V | tail -1)}
if [ "$current" = "$latest" ]; then echo "up to date: $current"; exit 0; fi
echo "chart $current -> $latest"

tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
cat >"$tmp/flake.nix" <<EOF
{
  inputs.nixpkgs.url = "$nixpkgs";
  inputs.amp.url = "path:$repo";
  outputs = { nixpkgs, amp, ... }: {
    server = nixpkgs.lib.nixosSystem {
      system = "x86_64-linux";
      modules = [ amp.nixosModules.default {
        boot.loader.grub.device = "nodev";
        fileSystems."/" = { device = "none"; fsType = "tmpfs"; };
        system.stateVersion = "25.11";
        services.amp-orbs = { enable = true; role = "server"; nodeIP = "192.168.1.10";
          appsDomain = "apps.example.com"; nas = { server = "192.168.1.5"; path = "/x"; }; };
      } ];
    };
  };
}
EOF
# Renders the manifest, which builds the chart and the patched main.js.
# Without its lock file it reads the repo again each time, with the hashes set since.
render() { rm -f "$tmp/flake.lock"; nix eval "${flags[@]}" --json "path:$tmp#server.config.services.k3s.manifests.amp-orbs.content" >/dev/null; }
sethash() { sed -i "s|outputHash = \"sha256-[^\"]*\";|outputHash = \"$2\";|" "$1"; }

sed -i "s|^  version = \"$current\";|  version = \"$latest\";|" orbs.nix
sethash orbs.nix "$fake"
sethash provider.nix "$fake"
# Each pass fails on the first hash still fake and prints the real one.
for _ in 1 2 3; do
  if out=$(render 2>&1); then echo "chart $latest renders; review the diff, then test it on a cluster"; exit 0; fi
  got=$(grep -oE 'got: +sha256-[A-Za-z0-9+/=]+' <<<"$out" | head -1 | awk '{print $2}' || true)
  if [ -z "$got" ]; then echo "$out" >&2; echo "chart $latest does not render with the overlay" >&2; exit 1; fi
  if grep -q "outputHash = \"$fake\"" orbs.nix; then sethash orbs.nix "$got"; else sethash provider.nix "$got"; fi
done
echo "$out" >&2; exit 1
