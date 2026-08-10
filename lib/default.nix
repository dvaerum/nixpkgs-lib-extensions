{ lib, ... }:
# The lib loader. Every file under lib/ is a function of ONE shape:
#
#   { lib, self, ... }: { <exported names> }
#
#     lib   nixpkgs' lib, for the pure helpers every file may want
#     self  the fully assembled nixpkgs-lib-extensions lib -- a fixed point,
#           so a file can call a sibling without importing it, and
#           context.nix can inspect the whole attrset to decide which lib
#           namespaces this repo owns
#
# A file may ignore either (`{ self, ... }:`, `{ ... }:`); the `...` is what
# makes that legal.
#
# The public surface is the `namespaces` list below and nothing else.
# Dropping a file into a folder does NOT publish it -- it has to be named
# here. That is also what makes `lib/nixos/internal/` private: those files
# are imported directly by their consumers and never appear in this list,
# so they are unreachable through the exported lib.
#
# (This replaced a readDir loader whose folders had TWO calling protocols:
# a folder with default.nix received nixpkgs' `lib`, one without received
# only `self`. Everything under lib/nixos and lib/imports therefore had no
# `lib` at all and was written in raw `builtins`.)
lib.fix (
  self:
  let
    load = path: import path { inherit lib self; };

    # This library's release -- flake-level METADATA, not a function file,
    # so it lives here rather than in a folder. Pre-1.0: the API breaks
    # freely between releases, without compatibility shims. It is reserved
    # in the collision check below (a lib file exporting `version` would
    # otherwise be shadowed silently) and excluded from the module-level
    # half (internal/module-level.nix): inside modules, `lib.version` is
    # nixpkgs' release and must stay so.
    version = "0.1.0";

    namespaces = lib.mapAttrs (_: paths: lib.mergeAttrsList (map load paths)) {
      attrsets = [ ./attrsets/default.nix ];
      strings = [ ./strings/default.nix ];
      disko = [ ./disko/declare-zfs-root-disk.nix ];
      imports = [
        ./imports/import-if-nix.nix
        ./imports/import-if-nix-or.nix
      ];
      nixos = [
        ./nixos/build-configurations.nix
        ./nixos/build-home-configurations.nix
        ./nixos/build-nixos-configurations.nix
        ./nixos/home-manager-bootstrap-module.nix
        ./nixos/mk-home-configuration.nix
        ./nixos/mk-nixos-system.nix
        ./nixos/normal-user-module.nix
      ];
    };

    # Every function is ALSO reachable unnamespaced -- `extLib.declareZfsRootDisk`
    # as well as `extLib.disko.declareZfsRootDisk`. Deliberate: the docs head
    # their reference with the namespaced name and every example uses the flat
    # one, and consumers are written against the flat one.
    #
    # Collisions THROW rather than last-write-winning: two folders exporting
    # the same name, or a function named like a folder, would otherwise shadow
    # each other depending on merge order.
    topLevel =
      let
        perName = lib.zipAttrs (lib.attrValues namespaces);
        duplicates = lib.attrNames (lib.filterAttrs (name: values: lib.length values > 1) perName);
        # `version` is claimed by the metadata above, so a function of that
        # name would be shadowed just like one named after a folder
        folderClashes = lib.filter (name: perName ? ${name}) (lib.attrNames namespaces ++ [ "version" ]);
        clashes = duplicates ++ folderClashes;
      in
      if clashes == [ ] then
        lib.mergeAttrsList (lib.attrValues namespaces)
      else
        throw "lib loader: top-level name collision(s): ${lib.concatStringsSep ", " clashes}";
  in
  # { attrsets = {...}; strings = {...}; <and the other namespaces> }
  #   // { func1 = ...; func2 = ...; }
  #   // { version = "..."; }
  namespaces // topLevel // { inherit version; }
)
