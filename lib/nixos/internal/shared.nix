# Shared helpers for the builders in lib/nixos (mkNixosSystem,
# mkHomeConfiguration and homeManagerBootstrapModule).
#
# This file is PRIVATE because lib/default.nix does not list it: the loader
# publishes exactly the files it names, and nothing under internal/ is named.
# The builder files import it directly:
#
#   { self, lib, ... }:
#   let shared = import ./internal/shared.nix { inherit lib self; }; in { ... }
#
# It is a thin AGGREGATOR: the implementations live in sibling files,
# grouped by concern, and this file only re-exports their union so the
# builder files keep that single import:
#
#   inputs.nix     input-convention introspection (detection, the channel
#                  conventions, inputContributions classification/selection)
#   registry.nix   userRegistry resolution (matching, validation, user lists)
#   context.nix    the shared evaluation context (mkContext)
#   mk-system.nix  the mkNixosSystem implementation (mkSystem)
#   mk-home.nix    the mkHomeConfiguration implementation (mkHome)
#   hosts-args.nix argument allowlists and hosts-attrset validation
#
# Like the builder files each of them takes the loader's `{ lib, self, ... }`:
# nixpkgs' lib, and the fully assembled nixpkgs-lib-extensions lib.
# Only what the builder files (and the tests) actually consume is
# re-exported: a name here that nothing imports is dead weight that reads
# like public surface.
{ lib, self, ... }:
{
  inherit (import ./inputs.nix { inherit lib self; }) detectHomeManager;
  inherit (import ./registry.nix { inherit lib self; })
    resolveUser
    usersFromRegistry
    usersWithHome
    loginUsersWithHome
    validateLoginUsers
    ;
  inherit (import ./context.nix { inherit lib self; }) coreArgNames mkContextCore mkContext;
  inherit (import ./mk-system.nix { inherit lib self; }) mkSystem;
  inherit (import ./mk-home.nix { inherit lib self; }) mkHome;
  inherit (import ./hosts-args.nix { inherit lib self; })
    allowedDefaultArgs
    validateBuilderArgs
    builderArgProblems
    splitHostsArgs
    hostsProblems
    planHosts
    systemsFromPlan
    homesFromPlan
    ;
}
