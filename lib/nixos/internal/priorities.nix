# PRIVATE, per ./shared.nix. Takes the loader's calling convention but
# needs only nixpkgs' `lib`.
#
# The priority of the builder's OWN defaults, shared by ext-options.nix
# (the `home.stateVersion` convenience default) and mk-system.nix (the
# `nixpkgs.hostPlatform` pin). One number, named once. It sits BETWEEN
# `lib.mkDefault` (1000) and the module system's option default
# (`mkOptionDefault`, 1500), so that
#
#   - a consumer's plain or `mkDefault` definition BEATS the builder's
#     default instead of colliding with it at equal priority -- the
#     builder's own warning recipes say `mkDefault`, so they must win --
#   - while the builder's default still beats an option's own default.
#
# "Pinned" therefore means: some definition is STRONGER (numerically
# lower) than builderDefaultPriority. A definition at `mkOptionDefault`
# strength is NOT a pin -- the builder's default wins it, unforced.
{ lib, ... }:
let
  builderDefaultPriority = 1250;
in
{
  inherit builderDefaultPriority;
  mkBuilderDefault = lib.mkOverride builderDefaultPriority;
}
