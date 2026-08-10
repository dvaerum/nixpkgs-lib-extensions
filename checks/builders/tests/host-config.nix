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
  repoDir,
  ...
}:
let
  shared = import (repoDir + "/lib/nixos/internal/shared.nix") {
    inherit lib;
    self = myLib;
  };
in
{
  hostname-set = laptop.config.networking.hostName == "laptop";

  # the unpatched route evaluates through nixpkgs.lib.nixosSystem, which
  # injects `nixpkgs.flake.source` -- registry/NIX_PATH pinning points at
  # the exact nixpkgs input the system was built from (a raw eval-config
  # import used to lose this silently). The PATCHED route's counterpart
  # lives in checks/nixpkgs-patching.nix.
  flake-source-is-the-nixpkgs-input =
    toString laptop.config.nixpkgs.flake.source == toString inputs.nixpkgs.outPath;

  # ── hosts/<hostname> convention ──
  # laptop's config comes from hosts/laptop.nix (file form), server's from
  # hosts/server/configuration.nix (directory form) -- neither passes
  # `modules` in the example
  auto-host-file-module = laptop.config.fileSystems."/".device == "/dev/sda1";
  auto-host-dir-module = server.config.fileSystems."/".device == "/dev/vda1";
  # with hostGroup set the lookup moves under hosts/<hostGroup>/ ...
  typed-host-convention =
    (myLib.mkNixosSystem {
      inherit inputs system;
      hostname = "typedhost";
      hostGroup = "vm";
      rootPath = fixturesDir + "/typed-root";
    }).config.users.groups ? typed-host-marker;
  # ... and without it the type folders are NOT searched (the same host
  # name resolves to nothing under the plain hosts/ of that root)
  untyped-ignores-type-folders =
    !(
      (myLib.mkNixosSystem {
        inherit inputs system;
        hostname = "typedhost";
        rootPath = fixturesDir + "/typed-root";
      }).config.users.groups ? typed-host-marker
    );

  # both forms existing for one host is ambiguous -> throw
  ambiguous-host-config-throws =
    !(builtins.tryEval
      (myLib.mkNixosSystem {
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
    (myLib.mkNixosSystem {
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
  host-group-option = custom.config.nixpkgsLibExtensions.hostGroup == "server";
  # a specialArg the builder does not own passes through untouched
  special-args-passed-through = custom._module.specialArgs.probeArg == "from-special-args";

  # ... but redefining a RESERVED name throws: the builder-owned specialArgs
  # (`rootPath`, `extLib`, ...) because overriding one produced a
  # split-brain host, and the MOVED names (`hostname`, `tags`, ...) because
  # a specialArg of one would mask its tombstone and diverge from the
  # `nixpkgsLibExtensions.*` options.
  special-args-shadow-throws =
    let
      shadows =
        name: value:
        !(builtins.tryEval (
          builtins.attrNames
            (myLib.mkNixosSystem {
              inherit inputs system;
              hostname = "shadowprobe";
              modules = [ (exampleDir + "/hosts/server/configuration.nix") ];
              specialArgs.${name} = value;
            })._module.specialArgs
        )).success;
    in
    shadows "hostname" "not-shadowprobe" && shadows "rootPath" "/tmp" && shadows "extLib" { };

  # the same check covers a shadow arriving through a host's `extra` slot,
  # which planHosts merges into specialArgs before the builder sees it
  extra-special-args-shadow-throws =
    !(builtins.tryEval (
      builtins.attrNames
        (myLib.buildNixosConfigurations {
          shadowprobe2 = {
            inherit inputs system;
            modules = [ (exampleDir + "/hosts/server/configuration.nix") ];
            extra.specialArgs.tags = [ "nope" ];
          };
        }).shadowprobe2._module.specialArgs
    )).success;

  # `_`-prefixed keys are no longer waved through the builder allowlist.
  # They were, so that planHosts could smuggle `_core` past it; the core is
  # an explicit parameter of the internal mkSystem now, so a `_defaults`
  # written INSIDE a host entry (rather than beside it) is reported instead
  # of silently accepted and ignored.
  underscore-key-not-waved-through =
    let
      problems = shared.builderArgProblems "probe" [ ] {
        _defaults = { };
      };
    in
    builtins.any (p: lib.hasInfix "_defaults" p) problems;

  # ... and `extra` in a DIRECT builder call is refused rather than
  # silently dropped: there is nothing to layer onto there
  extra-rejected-by-direct-call =
    !(builtins.tryEval (
      builtins.seq (myLib.mkNixosSystem {
        inherit inputs system;
        hostname = "directextra";
        extra.modules = [ ];
      }) true
    )).success;

  # no rootPath and no inputs.self: a clear throw, not a silent search
  # inside the library's own store tree
  missing-root-path-throws =
    !(builtins.tryEval
      (myLib.mkNixosSystem {
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
        (myLib.mkNixosSystem {
          inherit inputs system;
          hostname = "moduleoverlay";
          modules = [
            (exampleDir + "/hosts/server/configuration.nix")
            { nixpkgs.overlays = [ (final: prev: { from-module-overlay = "yes"; }) ]; }
          ];
        }).pkgs;
    in
    probe ? from-module-overlay && probe ? from-input-overlay;

  # a module-level `nixpkgs.hostPlatform` IS ignored (the injected pkgs
  # carries the platform), so the builder warns instead of staying silent
  # -- nixpkgs' readOnlyPkgs module would make it a hard error, but is
  # deliberately not imported because it also forbids the blessed
  # module-level nixpkgs.overlays compose path above
  module-level-host-platform-warns =
    builtins.any (w: lib.hasInfix "nixpkgs.hostPlatform" w)
      (myLib.mkNixosSystem {
        inherit inputs system;
        hostname = "platformprobe";
        modules = [
          (exampleDir + "/hosts/server/configuration.nix")
          { nixpkgs.hostPlatform = "aarch64-linux"; }
        ];
      }).config.warnings
    # ... and only then: an untouched host carries no such warning
    && !(builtins.any (w: lib.hasInfix "nixpkgs.hostPlatform" w) laptop.config.warnings);

  # ... while `nixpkgs.config` genuinely cannot be set that way: nixpkgs
  # asserts it must be empty when an externally built pkgs is passed in, so
  # the `nixpkgsConfig` builder argument is the only route for it.
  module-level-nixpkgs-config-fails-assertion =
    !(builtins.all (a: a.assertion)
      (myLib.mkNixosSystem {
        inherit inputs system;
        hostname = "moduleconfig";
        modules = [
          (exampleDir + "/hosts/server/configuration.nix")
          { nixpkgs.config.allowUnfree = true; }
        ];
      }).config.assertions
    );
  root-path-defaults-to-self = toString laptop._module.specialArgs.rootPath == toString exampleDir;
  extra-modules-applied = custom.config.users.groups ? from-additional-module;

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

  # `listOfUsernames` and `username` are layered AFTER specialArgs, so a
  # specialArg of either name was silently discarded -- the two names the
  # shadow check's own comment cites as proof the override promise was
  # false, and the only ones it did not cover
  reserved-layered-names-shadow-throws =
    let
      shadows =
        name: value:
        !(builtins.tryEval (
          builtins.attrNames
            (myLib.mkNixosSystem {
              inherit inputs system;
              hostname = "reservedprobe";
              modules = [ (exampleDir + "/hosts/server/configuration.nix") ];
              specialArgs.${name} = value;
            })._module.specialArgs
        )).success;
    in
    shadows "listOfUsernames" [ "injected" ] && shadows "username" "root";

  # a host entry that is not an attrset used to die with a bare
  # "expected a set but found a path" naming neither the function nor the
  # host -- and `laptop = ./hosts/laptop.nix;` is a natural thing to write
  # given this library's own hosts/<hostname>.nix convention
  host-entry-shape-throws =
    !(builtins.tryEval (
      builtins.attrNames (myLib.buildNixosConfigurations { laptop = exampleDir + "/hosts/laptop.nix"; })
    )).success;
  host-extra-shape-throws =
    !(builtins.tryEval (builtins.attrNames (myLib.buildNixosConfigurations { laptop.extra = [ 1 ]; })))
    .success;

  # `extra.<key>` ADDS; a type mismatch is never a deliberate add, and it
  # used to silently REPLACE the fleet-wide base (a forgotten pair of
  # brackets turned allowedUnfreePackages into a string, with the malformed
  # nixpkgs.config only biting much later)
  extra-type-mismatch-throws =
    !(builtins.tryEval (
      (myLib.buildNixosConfigurations {
        _defaults = {
          inherit inputs system;
          modules = [ (exampleDir + "/hosts/server/configuration.nix") ];
          allowedUnfreePackages = [ "vscode" ];
        };
        laptop.extra.allowedUnfreePackages = "steam";
      }).laptop.pkgs.config.allowUnfreePredicate
        { pname = "steam"; }
    )).success;
}
