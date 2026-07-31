# PRIVATE (not listed in lib/default.nix). Takes the one calling convention:
# `self` is the fully assembled nixpkgs-lib-extensions lib (a fixed point),
# `lib` is nixpkgs'.
#
# Which half of this repo's lib belongs in a MODULE's `lib`, and how it is
# merged in. There are three sites that must agree -- the module lib built in
# ./context.nix, and the flake's own `extendLib` and `overlays.default` -- so
# the rule lives here once.
{ lib, self, ... }:
let
  # The `nixos` namespace is FLAKE-level: it builds systems, and a module is
  # already inside one. `lib.buildConfigurations` inside a NixOS module was
  # never meaningful. Everything else is module-level.
  #
  # DERIVED from the namespace, not transcribed: a new file under lib/nixos
  # is flake-level automatically, a new one under lib/disko or lib/imports is
  # module-level automatically. A hand-written list would rot the first time
  # someone added a builder.
  moduleLevelLib =
    extLib: builtins.removeAttrs extLib ([ "nixos" ] ++ builtins.attrNames extLib.nixos);
in
{
  inherit moduleLevelLib;

  # The module-level half, ready to merge over `baseLib`, under the SAME rule
  # an INPUT's lib export gets (see inputLibAdditions in ./context.nix): the
  # existing side wins, an addition can only ADD.
  #
  # This repo used to `recursiveUpdate baseLib myLib` at all three sites, so
  # its own names beat nixpkgs' silently, everywhere -- exactly the failure
  # the input path goes to some trouble to prevent. A future nixpkgs function
  # colliding with one of ours would have lost without a word.
  #
  # Three classes, matching that path:
  #   name nixpkgs does not use  -> added
  #   attrset on BOTH sides      -> recursive merge, nixpkgs wins conflicts
  #     (this is how `attrsets.recursiveMerge` and `strings.stringToTitle`
  #     join namespaces nixpkgs also defines)
  #   any other collision        -> skipped with a warning
  addOwnLib =
    baseLib: extLib:
    let
      own = moduleLevelLib extLib;
      names = builtins.attrNames own;
      collides = n: baseLib ? ${n};
      mergeable = n: collides n && builtins.isAttrs baseLib.${n} && builtins.isAttrs own.${n};
      skipped = builtins.filter (n: collides n && !(mergeable n)) names;
      kept = builtins.mapAttrs (n: v: if mergeable n then lib.recursiveUpdate v baseLib.${n} else v) (
        builtins.removeAttrs own skipped
      );
    in
    if skipped == [ ] then
      kept
    else
      builtins.warn "nixpkgs-lib-extensions: not adding ${builtins.concatStringsSep ", " skipped} to the module `lib`: nixpkgs already defines ${if builtins.length skipped == 1 then "that name" else "those names"}, and an addition must never change an existing one. Reach them through the `extLib` specialArg, or rename them in this repo." kept;
}
