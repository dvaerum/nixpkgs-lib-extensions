# The `nixpkgsLibExtensions.*` options namespace: the builder-derived
# values that used to be specialArgs, now declared as real module options
# (NixOS AND both home mechanisms), plus the throwing tombstones behind the
# removed specialArgs.
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
  extOpts = import (repoDir + "/lib/nixos/internal/ext-options.nix") {
    inherit lib;
    self = myLib;
  };

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
  systemThrows =
    hostname: modules:
    !(builtins.tryEval (builtins.attrNames (probeSystem hostname modules).config.users.groups)).success;
  homeThrows =
    modules:
    !(builtins.tryEval (
      builtins.attrNames
        (myLib.mkHomeConfiguration {
          inherit inputs system;
          hostname = "laptop";
          username = "alice";
          userRegistry."alice" = exampleDir + "/users/alice";
          homeModules = modules;
        }).config.home.sessionVariables
    )).success;
in
{
  # ── the options hold the builder's values, in NixOS modules ──
  ext-options-hold-builder-values =
    custom.config.nixpkgsLibExtensions.group == "server"
    && custom.config.nixpkgsLibExtensions.tags == [ "kitchen-sink" ]
    && laptop.config.nixpkgsLibExtensions.group == null
    && laptop.config.nixpkgsLibExtensions.users == exampleUsers;

  # the canonical channels path mirrors the (legacy) pkgs-* specialArgs:
  # same variant key, same instantiation
  ext-channels-canonical-path =
    laptop.config.nixpkgsLibExtensions.channels.unstable.path
    == laptop._module.specialArgs.pkgs-unstable.path;

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

  # ── the removed specialArgs fail LOUDLY, not with a bare unknown-arg ──
  # each moved name still resolves as a module argument -- to a tombstone
  # that throws with the replacement path
  moved-arg-tags-throws = systemThrows "mvtags" [
    ({ tags, ... }: { users.groups.${builtins.seq tags "probe"} = { }; })
  ];
  moved-arg-hostname-throws = systemThrows "mvhost" [
    ({ hostname, ... }: { users.groups.${builtins.seq hostname "probe"} = { }; })
  ];
  moved-arg-host-group-throws = systemThrows "mvgroup" [
    ({ hostGroup, ... }: { users.groups.${builtins.seq hostGroup "probe"} = { }; })
  ];
  moved-arg-list-of-usernames-throws = systemThrows "mvusers" [
    ({ listOfUsernames, ... }: { users.groups.${builtins.seq listOfUsernames "probe"} = { }; })
  ];
  moved-arg-input-pkgs-throws = systemThrows "mvpkgs" [
    ({ inputPkgs, ... }: { users.groups.${builtins.seq inputPkgs "probe"} = { }; })
  ];
  # ... in home modules too
  moved-arg-throws-in-homes = homeThrows [
    (
      { listOfUsernames, ... }:
      {
        home.sessionVariables.${builtins.seq listOfUsernames "PROBE"} = "1";
      }
    )
  ];

  # tryEval discards a throw's message, so the tombstone TEXT is pinned as
  # data: every moved name points at its replacement, and the message names
  # that path (house style: the error text is tested API surface)
  moved-special-args-point-at-options =
    extOpts.movedNixosSpecialArgs == {
      hostname = "config.networking.hostName";
      tags = "config.nixpkgsLibExtensions.tags";
      hostGroup = "config.nixpkgsLibExtensions.group";
      listOfUsernames = "config.nixpkgsLibExtensions.users";
      inputPkgs = "config.nixpkgsLibExtensions.inputPkgs";
    }
    # a home has no networking.hostName; its tombstone points at the option
    # the home variant declares itself
    && extOpts.movedHomeSpecialArgs.hostname == "config.nixpkgsLibExtensions.hostname"
    && builtins.all (
      name:
      lib.hasInfix extOpts.movedNixosSpecialArgs.${name} (
        extOpts.movedSpecialArgMessage name extOpts.movedNixosSpecialArgs.${name}
      )
    ) (builtins.attrNames extOpts.movedNixosSpecialArgs);

  # the renamed OPTION path (`nixpkgsLibExtensions.hostGroup` ->
  # `nixpkgsLibExtensions.group`, 1.0.0) is a tombstone too; tryEval
  # discards the thrown text, so the pointer is pinned at the source
  ext-host-group-option-tombstone-names-replacement =
    lib.hasInfix "renamed to `nixpkgsLibExtensions.group`"
      (builtins.readFile (repoDir + "/lib/nixos/internal/ext-options.nix"));
}
