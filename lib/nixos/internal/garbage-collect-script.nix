# Builds the wrapped generation-retention script. Shared between
# systemGarbageCollectModule and checks/system-garbage-collect/script.nix
# (which passes a stub `nix-env` that serves a fixed listing and records
# deletions), so the test exercises exactly the wrapper used in
# production -- the same arrangement as ./auto-upgrade-script.nix.
{
  pkgs,
  nixPackage ? pkgs.nix,
  extraInputs ? [ ],
}:
{
  prune = pkgs.writeShellApplication {
    name = "nixos-prune-generations";
    runtimeInputs = [
      pkgs.coreutils # date, head, wc
      pkgs.gnugrep
      pkgs.gawk # generation id / timestamp columns
      # `nix-env --list-generations` and `--delete-generations` are the
      # only interface to a profile's generations; there is no library
      # call and no file format to read instead.
      nixPackage
    ]
    ++ extraInputs;
    text = builtins.readFile ../scripts/nixos-prune-generations.sh;
  };
}
