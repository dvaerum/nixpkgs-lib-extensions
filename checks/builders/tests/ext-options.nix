# The `nixpkgsLibExtensions.*` options namespace: the builder-derived
# per-host values, declared as real module options (NixOS AND both home
# mechanisms).
{
  lib,
  myLib,
  inputs,
  system,
  laptop,
  custom,
  aliceHome,
  mkProbeSystem,
  # the canonical example user list, shared through ctx so this file does
  # not keep a drifting private copy
  exampleUsers,
  exampleDir,
  repoDir,
  ...
}:
let
  # A host whose modules exercise the option under test; forcing the group
  # names reaches whatever the module read (or threw on).
  probeSystem =
    hostname: modules:
    mkProbeSystem {
      inherit inputs system hostname;
      modules = [ (exampleDir + "/hosts/server/configuration.nix") ] ++ modules;
    };

  # The declared `nixpkgsLibExtensions.*` option names, from the HOME
  # variant -- the superset (it adds `hostname`). ext-options.nix depends
  # only on `lib`, so it can be imported directly.
  declaredOptionNames =
    builtins.attrNames
      (
        (import (repoDir + "/lib/nixos/internal/ext-options.nix") {
          inherit lib;
          self = myLib;
        }).extHomeOptionsModule
        {
          hostname = "probe";
          group = null;
          tags = [ ];
          users = [ ];
          inputPkgs = { };
          channels = { };
        }
      ).options.nixpkgsLibExtensions;
in
{
  # ── the options hold the builder's values, in NixOS modules ──
  ext-options-hold-builder-values =
    custom.config.nixpkgsLibExtensions.group == "server"
    && custom.config.nixpkgsLibExtensions.tags == [ "kitchen-sink" ]
    && laptop.config.nixpkgsLibExtensions.group == null
    && laptop.config.nixpkgsLibExtensions.users == exampleUsers;

  # the channels option is keyed by variant and instantiates the variant's
  # tree (nixpkgs-unstable is aliased to nixpkgs in the test inputs)
  ext-channels-variant-tree =
    toString laptop.config.nixpkgsLibExtensions.channels.unstable.path
    == toString inputs.nixpkgs.outPath;

  # ... and a module reads them through `config` like any option
  ext-options-readable-from-module =
    (mkProbeSystem {
      inherit inputs system;
      hostname = "optread";
      group = "vm";
      modules = [
        (exampleDir + "/hosts/server/configuration.nix")
        (
          { config, ... }:
          {
            users.groups."group-of-${config.nixpkgsLibExtensions.group}" = { };
          }
        )
      ];
    }).config.users.groups ? group-of-vm;

  # ── both home mechanisms see the same namespace ──
  # SYSTEM-managed homes (home-manager.sharedModules) ...
  ext-options-reach-system-homes =
    laptop.config.home-manager.users.dave.nixpkgsLibExtensions.hostname == "laptop"
    && laptop.config.home-manager.users.dave.nixpkgsLibExtensions.users == exampleUsers;
  # ... and LOGIN-managed homes (standalone homeManagerConfiguration).
  # `hostname` is declared only in the HOME variant -- a home has no
  # networking.hostName to read.
  ext-options-reach-login-homes =
    # alice's home is HOST-LESS (she has no hosts/<h> override), so the
    # hostname option is null there -- see its own doc comment
    aliceHome.config.nixpkgsLibExtensions.hostname == null
    # a host-less home sees the users whose OWN directory carries config
    # -- not bob, who exists only via a hosts/<h> override
    &&
      aliceHome.config.nixpkgsLibExtensions.users == [
        "alice"
        "dave"
        "eve"
        "frank"
        "grace"
      ];

  # ── tags MERGE now: builder argument + module contributions ──
  ext-tags-merge-from-modules =
    let
      merged =
        (mkProbeSystem {
          inherit inputs system;
          hostname = "tagmerge";
          tags = [ "from-builder" ];
          modules = [
            (exampleDir + "/hosts/server/configuration.nix")
            { nixpkgsLibExtensions.tags = [ "from-module" ]; }
          ];
        }).config;
      expected = [
        "from-builder"
        "from-module"
      ];
    in
    lib.sort lib.lessThan merged.nixpkgsLibExtensions.tags == expected
    # the merged value labels the boot menu too (mkDefault)
    && lib.sort lib.lessThan merged.system.nixos.tags == expected;

  # the derived values are readOnly: a module defining one is rejected by
  # the module system (the old specialArg-shadow split brain, now guarded
  # without any bespoke machinery). The rejection fires when the OPTION is
  # read, so the probe forces the option itself.
  ext-host-group-read-only =
    !(builtins.tryEval
      (probeSystem "roprobe" [ { nixpkgsLibExtensions.group = "vm"; } ]).config.nixpkgsLibExtensions.group
    ).success;
  ext-users-read-only =
    !(builtins.tryEval
      (probeSystem "roprobe2" [ { nixpkgsLibExtensions.users = [ "mallory" ]; } ])
      .config.nixpkgsLibExtensions.users
    ).success;

  # the guide's `nixpkgsLibExtensions.*` table is the options REFERENCE,
  # and it cannot drift from the declarations, in either direction: every
  # declared option name appears in docs/getting-started.md as
  # `nixpkgsLibExtensions.<name>`, and every such mention in the guide
  # names a declared option.
  ext-options-documented-in-guide =
    let
      guide = builtins.readFile (repoDir + "/docs/getting-started.md");
      mentioned = lib.unique (
        lib.concatMap (m: if lib.isList m then m else [ ]) (
          builtins.split "nixpkgsLibExtensions\\.([a-zA-Z]+)" guide
        )
      );
    in
    builtins.all (n: builtins.elem n mentioned) declaredOptionNames
    && builtins.all (n: builtins.elem n declaredOptionNames) mentioned;

  # the reserved-specialArgs guard in context.nix tracks the options: its
  # option-backed names and the declared option names are the SAME set -- a
  # declared option whose name is not reserved would let a specialArg
  # split-brain it, silently. The home variant is compared because its
  # declarations are the superset: `hostname` is an option only there,
  # yet reserved everywhere. The one deliberate delta, `username`, is on
  # NEITHER side: reserved in context.nix for the same hazard, but wired
  # by both home mechanisms as a module ARGUMENT, never declared as an
  # option -- so it must stay out of the option-backed list too.
  reserved-names-match-declared-options =
    builtins.attrNames
      (import (repoDir + "/lib/nixos/internal/context.nix") {
        inherit lib;
        self = myLib;
      }).optionBackedReserved == declaredOptionNames;
}
