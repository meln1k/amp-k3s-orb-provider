{
  description = "Amp orbs on K3s: a NixOS module for the cluster's machines";

  outputs = { self }: {
    nixosModules.default = ./nixos.nix;
  };
}
