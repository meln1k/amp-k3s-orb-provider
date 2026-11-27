# The module's VM tests, as a flake of their own so the module's flake keeps no inputs. They need
# KVM: `nix flake check ./tests`, or one of them with `nix build -L ./tests#checks.x86_64-linux.cluster`
# (outside a git checkout: 'path:.?dir=tests#checks.x86_64-linux.cluster').
{
  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";

  outputs = { nixpkgs, ... }:
    let pkgs = nixpkgs.legacyPackages.x86_64-linux; in {
      checks.x86_64-linux = {
        cluster = import ./cluster.nix { inherit pkgs; };
        shutdown-drain = import ./shutdown-drain.nix { inherit pkgs; };
      };
    };
}
