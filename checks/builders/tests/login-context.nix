# `nixpkgsLibExtensionsLoginContext`: a `loginFlakeRef` source publishes
# its own builder context (`inputs`/`specialArgs`), and its users build
# with THAT context instead of the consuming flake's own. Reproduces the
# reported bug (a system-managed `loginFlakeRef` user whose source needs
# its own rootPath/specialArgs/auto-collected modules) both as a
# standalone home and as a system-managed one.
{
  lib,
  myLib,
  sharedInternal,
  inputs,
  system,
  mkProbeSystem,
  fixturesDir,
  exampleDir,
  ...
}:
let
  sourceDir = fixturesDir + "/tree-logincontext-source";

  # An input present ONLY in the source's OWN loginContext.inputs, never
  # the consumer's -- proves auto-collected homeModules/nixosModules
  # come from the SOURCE, not the caller. Both channels on one input:
  # a real cross-flake source (nix-it-in). home.nix ONLY -- a trusted
  # source's own NixOS modules are deliberately never auto-collected
  # for configuration.nix (see mk-system.nix's userNixosConfigs).
  fakeSourceAutoInput = {
    outPath = "/nix/store/fake-logincontext-auto-input";
    homeModules.default = {
      home.sessionVariables.SOURCE_AUTO_MODULE_MARKER = "yes";
    };
  };

  # The source's own `inputs`: its own `self` (so `rootPath` resolves to
  # the SOURCE tree via `mkContext`'s existing default, unmodified) plus
  # the marker module above. Reuses the harness's real
  # `nixpkgs`/`home-manager` -- a real cross-flake source usually pins
  # the SAME ones via `follows`, which this models.
  fakeSourceInputs = inputs // {
    self = {
      outPath = toString sourceDir;
    };
    fakeSourceAutoInput = fakeSourceAutoInput;
  };

  # Shaped like a real flake input (an `outPath`, so `source + "/users"`
  # in registry.nix's `scanOne` resolves) that ALSO exports
  # `nixpkgsLibExtensionsLoginContext` -- exactly what a real source
  # flake (e.g. home-manager-config) would export.
  fakeSourceWithLoginContext = {
    outPath = toString sourceDir;
    nixpkgsLibExtensionsLoginContext = {
      inputs = fakeSourceInputs;
      specialArgs = {
        sourceMarker = "from-source";
      };
    };
  };

  # Declares a DIFFERENT `system` than the caller's -- proves `system` is
  # force-merged from the actual call, never read off the loginContext
  # (cycle 5/10). A dedicated variant so every OTHER test keeps using the
  # harness's cheap, already-evaluated `system`.
  otherSystem = if system == "x86_64-linux" then "aarch64-linux" else "x86_64-linux";
  fakeSourceWithWrongSystem = {
    outPath = toString sourceDir;
    nixpkgsLibExtensionsLoginContext = {
      inputs = fakeSourceInputs;
      system = otherSystem;
      specialArgs = {
        sourceMarker = "from-source";
      };
    };
  };

  standaloneHome =
    {
      loginFlakeRef,
      rootPath ? exampleDir,
    }:
    myLib.mkHomeConfiguration {
      inherit
        inputs
        system
        rootPath
        loginFlakeRef
        ;
      username = "dennis";
    };

  # A plain-path source (no loginContext at all) -- the common,
  # pre-existing case, and cycle 1's regression fixture.
  plainSource = fixturesDir + "/tree-per";

  # A rootPath that ALSO exports a loginContext -- for OTHER consumers'
  # benefit (home-manager-config does exactly this so a THIRD flake can
  # use it), never meant to apply to the tree's OWN users. Caught live:
  # without `isRootPath` (registry.nix's `loginFlakeRefSources`), alice
  # here would be rebuilt from a FRESH core carrying only this
  # loginContext's `inputs`/`specialArgs`, silently losing whatever
  # `overlays`/`allowedUnfreePackages` the actual build call passed.
  selfExportingRootPath = {
    outPath = toString exampleDir;
    nixpkgsLibExtensionsLoginContext = {
      inherit inputs;
      specialArgs = {
        selfExportMarker = "should-not-apply-to-self";
      };
    };
  };

  systemManagedProbe = mkProbeSystem {
    inherit inputs system;
    hostname = "logincontext-system";
    users = [ "dennis" ];
    loginHomes = [ ]; # dennis is SYSTEM-managed: the reported bug's shape
    loginFlakeRef = fakeSourceWithLoginContext;
    rootPath = exampleDir; # the CONSUMER's own rootPath -- must NOT be used for dennis
  };

  # `allowNixosConfig = true`: configuration.nix is only ever imported
  # for a TRUSTED source (see registry.nix's loginFlakeRefSources) --
  # dennis's fixture configuration.nix (rootPath-relative, mirroring
  # home-manager-config's users/dvv/configuration.nix) needs a trusted
  # probe to be exercised at all.
  systemManagedTrustedProbe = mkProbeSystem {
    inherit inputs system;
    hostname = "logincontext-system-trusted";
    users = [ "dennis" ];
    loginHomes = [ ];
    loginFlakeRef = {
      source = fakeSourceWithLoginContext;
      allowNixosConfig = true;
    };
    rootPath = exampleDir;
  };
in
{
  # -- 1: regression -----------------------------------------------------
  # A `loginFlakeRef` source WITHOUT a `nixpkgsLibExtensionsLoginContext`
  # export is unaffected: `loginContextForUser` resolves to `null`, and
  # the OLD code path (mkContext core args / no per-user override) runs
  # exactly as before.
  no-login-context-resolves-to-null =
    let
      r = sharedInternal.resolveUsers {
        sources = sharedInternal.loginFlakeRefSources plainSource null;
        label = "t";
        traceDiscoveredUsers = false;
      };
    in
    sharedInternal.loginContextForUser r.userLoginContext "per" == null;

  no-login-context-home-builds-unaffected =
    (mkProbeSystem {
      inherit inputs system;
      hostname = "logincontext-regression";
      users = [ "per" ];
      loginFlakeRef = plainSource;
    }).config.home-manager.users.per.home.stateVersion == "26.11";

  # -- 2..6: standalone ----------------------------------------------------

  standalone-specialargs-from-source =
    (standaloneHome { loginFlakeRef = fakeSourceWithLoginContext; })
    .config.home.sessionVariables.SOURCE_SPECIALARG_MARKER == "from-source";

  standalone-rootpath-from-source =
    (standaloneHome { loginFlakeRef = fakeSourceWithLoginContext; })
    .config.home.sessionVariables.SOURCE_ROOTPATH_MARKER == "reached-via-source-rootpath";

  standalone-auto-modules-from-source =
    (standaloneHome { loginFlakeRef = fakeSourceWithLoginContext; })
    .config.home.sessionVariables.SOURCE_AUTO_MODULE_MARKER == "yes";

  standalone-system-forced-from-caller =
    (standaloneHome { loginFlakeRef = fakeSourceWithWrongSystem; }).config.nixpkgs.system == system;

  # Two sources in one call: source A's marker must not leak into a home
  # built from a source with no loginContext at all, and vice versa.
  standalone-no-cross-contamination =
    let
      sourced = standaloneHome { loginFlakeRef = fakeSourceWithLoginContext; };
      plain = myLib.mkHomeConfiguration {
        inherit inputs system;
        rootPath = exampleDir;
        username = "alice";
      };
    in
    (sourced.config.home.sessionVariables ? SOURCE_SPECIALARG_MARKER)
    && !(plain.config.home.sessionVariables ? SOURCE_SPECIALARG_MARKER);

  # A `users/<u>/_defaults.nix` function-form file gets the SAME
  # rootPath override home.nix/configuration.nix already get -- it
  # predates the loginContext feature and was never wired to it.
  user-defaults-nix-rootpath-from-source =
    let
      built = myLib.buildHomeConfigurations {
        inherit inputs system;
        rootPath = exampleDir;
        loginFlakeRef = fakeSourceWithLoginContext;
        users = [ "hugo" ];
      };
    in
    built."hugo".config.home.sessionVariables.SOURCE_ROOTPATH_MARKER == "reached-via-source-rootpath";

  # A loginContext missing BOTH `rootPath` and `inputs.self` must throw
  # naming the problem -- not silently hand `_defaults.nix` the
  # CONSUMER's own rootPath. Found by adversarial review: the original
  # fix's `contextInputsAndRootPathFor` diverged from its sibling
  # `loginContextOverridesFor` (mk-system.nix), which already throws in
  # this exact situation for home.nix/configuration.nix.
  user-defaults-nix-throws-when-source-has-no-rootpath-and-no-self =
    let
      sourceWithNoRootPathOrSelf = {
        outPath = toString sourceDir;
        nixpkgsLibExtensionsLoginContext = {
          # `self` must be genuinely ABSENT, not merely null -- `or`
          # only falls through when the attribute doesn't exist at all.
          inputs = removeAttrs fakeSourceInputs [ "self" ];
        };
      };
    in
    !(builtins.tryEval
      (myLib.buildHomeConfigurations {
        inherit inputs system;
        rootPath = exampleDir;
        loginFlakeRef = sourceWithNoRootPathOrSelf;
        users = [ "hugo" ];
      }).hugo.config.home.username
    ).success;

  # -- 7..10: system-managed -----------------------------------------------

  system-managed-specialargs-from-source =
    systemManagedProbe.config.home-manager.users.dennis.home.sessionVariables.SOURCE_SPECIALARG_MARKER
    == "from-source";

  system-managed-auto-modules-from-source =
    systemManagedProbe.config.home-manager.users.dennis.home.sessionVariables.SOURCE_AUTO_MODULE_MARKER
    == "yes";

  system-managed-rootpath-from-source =
    systemManagedProbe.config.home-manager.users.dennis.home.sessionVariables.SOURCE_ROOTPATH_MARKER
    == "reached-via-source-rootpath";

  # Regression: a trusted source's OWN auto-collected home.nix modules
  # must not collide with the CONSUMER's own -- found by adversarial
  # review (the same collision class as `no-duplicate-nixos-module-
  # from-source` below, but for home-manager's `sharedModules`/`imports`
  # merge instead of the flat NixOS `modules` list, which the system-
  # managed path DOES merge unlike mk-home.nix's standalone full swap).
  # Two DIFFERENT store paths, same option, same INPUT NAME -- the name
  # match is what `homeModulesFromLoginContext` now excludes on, mirroring
  # exactly the shape a missing `follows` produces.
  no-duplicate-home-module-from-source =
    let
      sharedModuleShape =
        { lib, ... }:
        {
          options.programs.sharedHomeModuleProbe.enable = lib.mkEnableOption "shared home module regression probe";
        };
      consumerSharedInput = {
        outPath = "/nix/store/consumer-shared-home-module-probe";
        homeModules.default = sharedModuleShape;
      };
      sourceSharedInput = {
        outPath = "/nix/store/source-shared-home-module-probe-DIFFERENT";
        homeModules.default = sharedModuleShape;
      };
      probe = myLib.mkNixosSystem {
        inputs = inputs // {
          sharedHomeModuleProbeInput = consumerSharedInput;
        };
        inherit system;
        hostname = "logincontext-no-duplicate-home-module";
        users = [ "dennis" ];
        loginHomes = [ ];
        loginFlakeRef = fakeSourceWithLoginContext // {
          nixpkgsLibExtensionsLoginContext = fakeSourceWithLoginContext.nixpkgsLibExtensionsLoginContext // {
            inputs = fakeSourceInputs // {
              sharedHomeModuleProbeInput = sourceSharedInput;
            };
          };
        };
        rootPath = exampleDir;
      };
    in
    (builtins.tryEval probe.config.home-manager.users.dennis.programs.sharedHomeModuleProbe.enable)
    .success;

  # the system's own pkgs build the home regardless of loginContext --
  # never a separate nixpkgs eval from the source. Uses the
  # wrong-system variant: if `system`/`nixpkgs` were ever read off the
  # loginContext for a system-managed home, this host would fail to
  # evaluate at all (two conflicting systems in one NixOS closure).
  system-managed-shares-host-pkgs =
    let
      probe = mkProbeSystem {
        inherit inputs system;
        hostname = "logincontext-system-wrongsys";
        users = [ "dennis" ];
        loginHomes = [ ];
        loginFlakeRef = fakeSourceWithWrongSystem;
        rootPath = exampleDir;
      };
    in
    probe.config.home-manager.users.dennis.home.stateVersion == "24.05"
    && probe.pkgs.stdenv.hostPlatform.system == system;

  # A trusted source's configuration.nix needs the SAME rootPath
  # override home.nix already gets -- userNixosConfigs (mk-system.nix)
  # is a separate code path from the per-user home-manager submodule,
  # and the original loginContext feature only wrapped the latter. Found
  # live: home-manager-config's users/dvv/configuration.nix imports a
  # sibling's configuration.nix via `rootPath`, which broke the moment
  # nixos-developer-system (a consumer with no users/ tree of its own)
  # built dvv system-managed from it.
  system-managed-configuration-nix-rootpath-from-source =
    systemManagedTrustedProbe.config.users.groups ? source-rootpath-nixos-marker;

  # Regression: a trusted source's NixOS modules are NEVER
  # auto-collected (unlike home.nix's autoHomeModules) -- found live
  # (home-manager-config/celler, both pulled in independently, no
  # `follows` tying them to one resolved copy) as "option already
  # declared", the instant a consumer's own top-level input and a
  # loginContext source's happened to overlap. Two DIFFERENT store
  # paths exporting the SAME option, mirroring that exactly -- must not
  # throw, because the source's copy must simply never be imported.
  no-duplicate-nixos-module-from-source =
    let
      sharedModuleShape =
        { lib, ... }:
        {
          options.services.sharedModuleProbe.enable = lib.mkEnableOption "shared module regression probe";
        };
      consumerSharedInput = {
        outPath = "/nix/store/consumer-shared-module-probe";
        nixosModules.default = sharedModuleShape;
      };
      sourceSharedInput = {
        outPath = "/nix/store/source-shared-module-probe-DIFFERENT";
        nixosModules.default = sharedModuleShape;
      };
      probe = myLib.mkNixosSystem {
        inputs = inputs // {
          sharedModuleProbeInput = consumerSharedInput;
        };
        inherit system;
        hostname = "logincontext-no-duplicate-module";
        users = [ "dennis" ];
        loginHomes = [ ];
        loginFlakeRef = {
          source = {
            outPath = toString sourceDir;
            nixpkgsLibExtensionsLoginContext = {
              inputs = fakeSourceInputs // {
                sharedModuleProbeInput = sourceSharedInput;
              };
              specialArgs = {
                sourceMarker = "from-source";
              };
            };
          };
          allowNixosConfig = true;
        };
        rootPath = exampleDir;
      };
    in
    (builtins.tryEval probe.config.services.sharedModuleProbe.enable).success;

  # -- 11: untrusted source, ungated ---------------------------------------

  untrusted-source-login-context-still-applies =
    (mkProbeSystem {
      inherit inputs system;
      hostname = "logincontext-untrusted";
      users = [ "dennis" ];
      loginHomes = [ ];
      loginFlakeRef = [ fakeSourceWithLoginContext ]; # list form: untrusted unless wrapped
    }).config.home-manager.users.dennis.home.sessionVariables.SOURCE_SPECIALARG_MARKER == "from-source";

  # -- 13: a self-exporting rootPath is never its own loginContext source --

  self-exporting-rootpath-keeps-shared-core-overlays =
    (myLib.mkHomeConfiguration {
      inherit inputs system;
      rootPath = selfExportingRootPath;
      username = "alice";
      overlays = [ (final: prev: { selfRootPathOverlayMarker = "present"; }) ];
    }).pkgs.selfRootPathOverlayMarker or null == "present";

  # A self-exporting rootPath must not change the core AT ALL for its
  # own tree's users -- same `pkgs` derivation as an identical build
  # whose rootPath does NOT export a loginContext. `? selfExportMarker`
  # alone would not prove this (alice's home.nix never destructures
  # that name, so an unused extra specialArg is silently harmless
  # either way) -- core identity is the only real proof.
  self-exporting-rootpath-shares-core-with-plain-rootpath =
    let
      withExport = myLib.mkHomeConfiguration {
        inherit inputs system;
        rootPath = selfExportingRootPath;
        username = "alice";
      };
      plain = myLib.mkHomeConfiguration {
        inherit inputs system;
        rootPath = exampleDir;
        username = "alice";
      };
    in
    withExport.pkgs.hello.outPath == plain.pkgs.hello.outPath;

  # -- 12: laziness ---------------------------------------------------------

  # A plain-path source (no `nixpkgsLibExtensions` attribute at all, the
  # common today's-fleet case) must never be attribute-probed in a way
  # that throws.
  plain-path-source-scan-does-not-throw =
    (builtins.tryEval (
      sharedInternal.resolveUsers {
        sources = sharedInternal.loginFlakeRefSources plainSource null;
        label = "t";
        traceDiscoveredUsers = false;
      }
    )).success;
}
