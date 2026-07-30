# Shared helpers for the builders in lib/nixos (nixosConfigurationsBuilder,
# homeConfigurationsBuilder and homeManagerBootstrapModule).
#
# This file lives in a subfolder so the lib loader (lib/default.nix) does not
# pick it up as part of the public lib; the builder files import it directly:
#
#   extLib: let shared = import ./internal/shared.nix extLib; in { ... }
#
# It is a thin AGGREGATOR: the implementations live in sibling files,
# grouped by concern, and this file only re-exports their union so the
# builder files keep that single import:
#
#   inputs.nix     input-convention introspection (detection, the channel
#                  conventions, inputSpecialCases classification/selection)
#   registry.nix   userRegistry resolution (matching, validation, user lists)
#   context.nix    the shared evaluation context (mkContext)
#   hosts-args.nix argument allowlists and hosts-attrset validation
#
# Like the builder files each of them is a function of `extLib` — the fully
# assembled nixpkgs-lib-extensions lib.
# Only what the builder files (and the tests) actually consume is
# re-exported: a name here that nothing imports is dead weight that reads
# like public surface.
extLib: {
  inherit (import ./inputs.nix extLib) detectHomeManager;
  inherit (import ./registry.nix extLib)
    resolveUser
    usersFromRegistry
    usersWithHome
    loginUsersWithHome
    validateLoginUsers
    ;
  inherit (import ./context.nix extLib) coreArgNames mkContextCore mkContext;
  inherit (import ./hosts-args.nix extLib)
    allowedDefaultArgs
    validateBuilderArgs
    splitHostsArgs
    ;
}
