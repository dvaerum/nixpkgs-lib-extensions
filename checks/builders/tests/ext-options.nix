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
  exampleDir,
  repoDir,
  ...
}:
let
  exampleUsers = [
    "alice"
    "bob"
    "dave"
    "eve"
    "frank"
    "grace"
  ];

  # A host whose modules exercise the option under test; forcing the group
  # names reaches whatever the module read (or threw on).
  probeSystem =
    hostname: modules:
    myLib.mkNixosSystem {
      inherit inputs system hostname;
      modules = [ (exampleDir + "/hosts/server/configuration.nix") ] ++ modules;
    };
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
    (myLib.mkNixosSystem {
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
    aliceHome.config.nixpkgsLibExtensions.hostname == "laptop"
    && aliceHome.config.nixpkgsLibExtensions.users == exampleUsers;

  # ── tags MERGE now: builder argument + module contributions ──
  ext-tags-merge-from-modules =
    let
      merged =
        (myLib.mkNixosSystem {
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
  # names a declared option. The HOME variant is the superset (it adds
  # `hostname`), so its declaration set is the one compared.
  ext-options-documented-in-guide =
    let
      extOpts = import (repoDir + "/lib/nixos/internal/ext-options.nix") {
        inherit lib;
        self = myLib;
      };
      declared =
        builtins.attrNames
          (extOpts.extHomeOptionsModule {
            hostname = "probe";
            group = null;
            tags = [ ];
            users = [ ];
            inputPkgs = { };
            channels = { };
          }).options.nixpkgsLibExtensions;
      guide = builtins.readFile (repoDir + "/docs/getting-started.md");
      mentioned = lib.unique (
        lib.concatMap (m: if lib.isList m then m else [ ]) (
          builtins.split "nixpkgsLibExtensions\\.([a-zA-Z]+)" guide
        )
      );
    in
    builtins.all (n: builtins.elem n mentioned) declared
    && builtins.all (n: builtins.elem n declared) mentioned;
}
