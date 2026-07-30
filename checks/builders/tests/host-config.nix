# Host-level configuration: the hosts/<hostname> convention, the config
# knobs exercised by the kitchen-sink `custom` host, buildNixosConfigurations
# key handling, and nixpkgs patching.
{
  lib,
  myLib,
  inputs,
  system,
  laptop,
  server,
  custom,
  fixturesDir,
  invalidFixturesDir,
  exampleDir,
  ...
}:
{
  hostname-set = laptop.config.networking.hostName == "laptop";

  # ── hosts/<hostname> convention ──
  # laptop's config comes from hosts/laptop.nix (file form), server's from
  # hosts/server/configuration.nix (directory form) -- neither passes
  # `modules` in the example
  auto-host-file-module = laptop.config.fileSystems."/".device == "/dev/sda1";
  auto-host-dir-module = server.config.fileSystems."/".device == "/dev/vda1";
  # with systemType set the lookup moves under hosts/<systemType>/ ...
  typed-host-convention =
    (myLib.nixosConfigurationsBuilder {
      inherit inputs system;
      hostname = "typedhost";
      systemType = "vm";
      rootPath = fixturesDir + "/typed-root";
    }).config.users.groups ? typed-host-marker;
  # ... and without it the type folders are NOT searched (the same host
  # name resolves to nothing under the plain hosts/ of that root)
  untyped-ignores-type-folders =
    !(
      (myLib.nixosConfigurationsBuilder {
        inherit inputs system;
        hostname = "typedhost";
        rootPath = fixturesDir + "/typed-root";
      }).config.users.groups ? typed-host-marker
    );

  # both forms existing for one host is ambiguous -> throw
  ambiguous-host-config-throws =
    !(builtins.tryEval
      (myLib.nixosConfigurationsBuilder {
        inherit inputs system;
        hostname = "both";
        rootPath = invalidFixturesDir + "/root-both";
      }).config.networking.hostName
    ).success;

  # ── kitchen-sink host: the remaining config knobs ──
  extra-overlays-applied = custom.pkgs ? from-extra-overlay;
  unfree-predicate-allows = custom.pkgs.config.allowUnfreePredicate { pname = "allowed-unfree"; };
  unfree-predicate-denies = !(custom.pkgs.config.allowUnfreePredicate { pname = "not-allowed"; });
  # nixpkgsConfig is the escape hatch into nixpkgs.config
  nixpkgs-config-reaches-pkgs = custom.pkgs.config.cudaSupport && !laptop.pkgs.config.cudaSupport;
  # ... merged LAST: it can override what the allowedUnfreePackages
  # shorthand produced
  nixpkgs-config-overrides-unfree-shorthand =
    (myLib.nixosConfigurationsBuilder {
      inherit inputs system;
      hostname = "unfreeoverride";
      modules = [ (exampleDir + "/hosts/server/configuration.nix") ];
      allowedUnfreePackages = [ ];
      nixpkgsConfig.allowUnfreePredicate = _: true;
    }).pkgs.config.allowUnfreePredicate
      { pname = "anything"; };
  # tags also label the boot entry (mkDefault); no tags -> NixOS default []
  tags-set-as-system-nixos-tags =
    custom.config.system.nixos.tags == [ "kitchen-sink" ] && laptop.config.system.nixos.tags == [ ];
  system-type-special-arg = custom._module.specialArgs.systemType == "server";
  # a specialArg the builder does not own passes through untouched
  special-args-passed-through = custom._module.specialArgs.probeArg == "from-special-args";

  # ... but redefining a builder-OWNED name throws. It used to "work" and
  # produce a split-brain host: `specialArgs.hostname` reached modules while
  # networking.hostName and the hosts/<hostname> lookup kept the real name,
  # and `rootPath`/`systemType` silently moved that lookup. The override
  # promise was never true anyway -- listOfUsernames and username are
  # layered afterwards and were never overridable.
  special-args-shadow-throws =
    let
      shadows =
        name: value:
        !(builtins.tryEval (
          builtins.attrNames
            (myLib.nixosConfigurationsBuilder {
              inherit inputs system;
              hostname = "shadowprobe";
              modules = [ (exampleDir + "/hosts/server/configuration.nix") ];
              specialArgs.${name} = value;
            })._module.specialArgs
        )).success;
    in
    shadows "hostname" "not-shadowprobe" && shadows "rootPath" "/tmp" && shadows "extLib" { };

  # the same check covers the per-host half of the pair
  additional-special-args-shadow-throws =
    !(builtins.tryEval (
      builtins.attrNames
        (myLib.nixosConfigurationsBuilder {
          inherit inputs system;
          hostname = "shadowprobe2";
          modules = [ (exampleDir + "/hosts/server/configuration.nix") ];
          additionalSpecialArgs.tags = [ "nope" ];
        })._module.specialArgs
    )).success;

  # no rootPath and no inputs.self: a clear throw, not a silent search
  # inside the library's own store tree
  missing-root-path-throws =
    !(builtins.tryEval
      (myLib.nixosConfigurationsBuilder {
        inputs = {
          inherit (inputs) nixpkgs home-manager;
        };
        inherit system;
        hostname = "noroot";
        modules = [ (exampleDir + "/hosts/server/configuration.nix") ];
      }).config.networking.hostName
    ).success;

  # A module-level `nixpkgs.overlays` DOES take effect, and composes with
  # the builder's own: passing `pkgs` as an eval-config argument sets the
  # `nixpkgs.pkgs` option, and the nixpkgs module then evaluates
  # `cfg.pkgs.appendOverlays cfg.overlays`. (This repo once warned that the
  # option was inert -- it never was.)
  module-level-overlay-applies =
    let
      probe =
        (myLib.nixosConfigurationsBuilder {
          inherit inputs system;
          hostname = "moduleoverlay";
          modules = [
            (exampleDir + "/hosts/server/configuration.nix")
            { nixpkgs.overlays = [ (final: prev: { from-module-overlay = "yes"; }) ]; }
          ];
        }).pkgs;
    in
    probe ? from-module-overlay && probe ? from-input-overlay;

  # ... while `nixpkgs.config` genuinely cannot be set that way: nixpkgs
  # asserts it must be empty when an externally built pkgs is passed in, so
  # the `nixpkgsConfig` builder argument is the only route for it.
  module-level-nixpkgs-config-fails-assertion =
    !(builtins.all (a: a.assertion)
      (myLib.nixosConfigurationsBuilder {
        inherit inputs system;
        hostname = "moduleconfig";
        modules = [
          (exampleDir + "/hosts/server/configuration.nix")
          { nixpkgs.config.allowUnfree = true; }
        ];
      }).config.assertions
    );
  root-path-defaults-to-self = toString laptop._module.specialArgs.rootPath == toString exampleDir;
  additional-modules-applied = custom.config.users.groups ? from-additional-module;

  # buildNixosConfigurations keys its input by hostname; a redundant inner
  # hostname EQUAL to the key is tolerated ...
  matching-inner-hostname-tolerated = builtins.isAttrs (
    (myLib.buildNixosConfigurations {
      dupok = {
        inherit inputs system;
        hostname = "dupok";
        modules = [ (exampleDir + "/hosts/server/configuration.nix") ];
      };
    }).dupok
  );
  # ... while a CONFLICTING inner hostname throws
  conflicting-hostname-throws =
    !(builtins.tryEval
      (myLib.buildNixosConfigurations {
        laptop = {
          inherit inputs system;
          hostname = "other-name";
          modules = [ (exampleDir + "/hosts/server/configuration.nix") ];
        };
      }).laptop
    ).success;

  # (the `patches` argument has its own check: checks/nixpkgs-patching.nix,
  # split out because verifying it is import-from-derivation over the whole
  # nixpkgs tree and blocked every cheap assertion here)
}
