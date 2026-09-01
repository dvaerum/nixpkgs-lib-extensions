# PRIVATE, per the calling convention documented in ./shared.nix.
#
# `mkSystem` is the mkNixosSystem implementation with the
# evaluation core as an EXPLICIT parameter rather than a `_core` key smuggled
# through the public argument attrset. That is the whole reason this file
# exists: planHosts has a core to hand over, and everything reachable from
# `self` is public, so an internal entry point has to live here.
#
# `core = null` means "compute one from these arguments" (the direct-call
# case); a plan hands over the core it already built, so N hosts that stick
# to `_defaults` share ONE nixpkgs evaluation.
#
# Arguments arrive ALREADY VALIDATED -- the public wrapper and planHosts each
# validate before calling, with their own function name in the message.
{ lib, self, ... }:
let
  inherit (import ./context.nix { inherit lib self; }) mkContext;
  inherit (import ./ext-options.nix { inherit lib self; })
    extNixosOptionsModule
    extHomeOptionsModule
    homeStateVersionModule
    ;
  inherit (import ./registry.nix { inherit lib self; })
    resolveUser
    usersFromRegistry
    usersWithHome
    resolveUserRegistry
    ;
  inherit (import ./priorities.nix { inherit lib; }) builderDefaultPriority mkBuilderDefault;
in
{
  mkSystem =
    core:
    {
      inputs,
      hostname,
      system,
      modules ? [ ],
      userModule ? self.normalUserModule,
      userRegistry ? { },
      loginHomes ? [ ],
      homeModules ? [ ],
      loginFlakeRef ? null,
      loginReactivateEveryLogin ? false,
      traceDiscoveredUsers ? true,
      tags ? [ ],
      group ? null,
      hostFolder ? null,
      ...
    }@args:
    let
      ctx = mkContext core args;
      inherit (ctx)
        lib
        pkgs
        selectedSrc
        mySpecialArguments
        autoNixosModules
        autoHomeModules
        home-manager
        nixpkgsInput
        nixpkgsPatched
        ;

      # The builder-derived values every module reads as the
      # `nixpkgsLibExtensions.*` options (plus `hostname` for the home
      # variant, where no networking.hostName exists).
      extOptionValues = {
        inherit group tags users;
        inherit (ctx) inputPkgs channels;
      };

      registry = resolveUserRegistry {
        wasGiven = args ? userRegistry;
        inherit
          userRegistry
          inputs
          loginFlakeRef
          hostname
          traceDiscoveredUsers
          ;
      };

      # The host's users, derived from the registry keys ("<user>@<host>"
      # for this host plus plain "<user>" fallback entries). `loginHomes`
      # selects a SUBSET of them whose homes are login-managed; everyone
      # else's home is system-managed. Disjoint by construction.
      users = usersFromRegistry registry hostname;

      perUserModules = lib.optionals (userModule != null) (lib.forEach users userModule);

      # Every matched registry directory may ship a configuration.nix
      # (e.g. creating the user's account and groups); all of them are
      # applied to the system automatically -- for login-managed users too.
      userNixosConfigs = lib.concatMap (u: (resolveUser registry hostname u).nixosModules) users;

      # SYSTEM-MANAGED HOMES: the home.nix of every user NOT in
      # `loginHomes` is wired into the system via home-manager's NixOS
      # module -- homes ship with the system and activate on
      # nixos-rebuild switch. No flake outputs, no bootstrap involved.
      systemUsersWithHome = lib.filter (u: !(lib.elem u loginHomes)) (usersWithHome registry hostname);
      hmNixosModule =
        if home-manager == null then
          null
        else
          home-manager.nixosModules.default or home-manager.nixosModules.home-manager or null;
      # Users would be getting NOTHING for their home.nix -- fail loudly
      # instead of silently building a homeless system.
      wantSystemHomes =
        if systemUsersWithHome != [ ] && hmNixosModule == null then
          lib.warn "mkNixosSystem: host `${hostname}`: user(s) ${lib.concatStringsSep ", " systemUsersWithHome} have a home.nix, but no home-manager input (or none exposing a NixOS module) exists -- their SYSTEM-managed homes are NOT built. Add a home-manager input, or move them to loginHomes." false
        else
          systemUsersWithHome != [ ] && hmNixosModule != null;
      systemHomesModule = {
        _file = ../mk-nixos-system.nix;
        imports = lib.optional wantSystemHomes (
          { ... }:
          {
            imports = [ hmNixosModule ];
            home-manager = {
              # the system's package set, not a second nixpkgs eval;
              # both mkDefault: override in your own modules if needed
              useGlobalPkgs = lib.mkDefault true;
              useUserPackages = lib.mkDefault true;
              extraSpecialArgs = mySpecialArguments;
              sharedModules =
                autoHomeModules
                ++ homeModules
                ++ [
                  # the same `nixpkgsLibExtensions.*` options inside every
                  # home that the system's own modules see
                  (extHomeOptionsModule (extOptionValues // { inherit hostname; }))
                  # home.stateVersion default (current release) -- with a
                  # warning for any home that RELIES on it
                  (homeStateVersionModule hostname)
                ];
              users = lib.genAttrs systemUsersWithHome (u: {
                # `username` as a module arg (extraSpecialArgs cannot
                # vary per user)
                _module.args.username = u;
                imports = (resolveUser registry hostname u).homeModules;
              });
            };
          }
        );
      };

      # The host's own configuration, by convention relative to `rootPath`
      # (default: the consuming flake, `inputs.self`): either
      # hosts/<hostname>.nix or hosts/<hostname>/configuration.nix -- and
      # when `group` (or its override `hostFolder`, which decouples the
      # folder from the classification) is set, grouped one level deeper
      # under hosts/<segment>/.
      autoHostModules =
        let
          folderSegment = if hostFolder != null then hostFolder else group;
          hostsDir =
            mySpecialArguments.rootPath
            + (if folderSegment == null then "/hosts" else "/hosts/${folderSegment}");
          file = hostsDir + "/${hostname}.nix";
          dir = hostsDir + "/${hostname}/configuration.nix";
          fileExists = lib.pathExists file;
          dirExists = lib.pathExists dir;
        in
        if fileExists && dirExists then
          throw ''
            mkNixosSystem: host `${hostname}` has both
            ${toString file} and ${toString dir}; keep only one.
          ''
        else
          lib.optional fileExists file ++ lib.optional dirExists dir;

      # LOGIN-MANAGED HOMES: for `loginHomes` the bootstrap runs
      # `home-manager switch --flake <loginFlakeRef>#<user>@<host>` on
      # first login -- the flake must export those homeConfigurations
      # outputs (see buildHomeConfigurations). Self-gating: empty module
      # when no login user matches or no home-manager input exists.
      bootstrapModule = self.homeManagerBootstrapModule {
        inherit
          inputs
          hostname
          system
          loginHomes
          loginFlakeRef
          loginReactivateEveryLogin
          ;
        userRegistry = registry;
        # the context's pick (honoring the homeManager override), so the
        # bootstrap cannot detect a DIFFERENT input than the system homes
        homeManager = home-manager;
      };
    in
    # What BOTH evaluation routes below receive. `system` is deliberately
    # not among the eval-config arguments anymore: that set the legacy
    # `nixpkgs.system` option, while the inline module pins
    # `nixpkgs.hostPlatform` instead (current upstream practice). With
    # `pkgs` passed in, neither is used to CONSTRUCT the package set --
    # the nixpkgs module wraps the given one -- but modules and tooling
    # read `config.nixpkgs.hostPlatform`, so it must hold a value.
    let
      evalArgs = {
        inherit lib pkgs;
        specialArgs = mySpecialArguments;
        modules = [
          # the builder-derived values as declared options -- always imported
          (extNixosOptionsModule extOptionValues)
          # nixpkgs' `nixosModules.readOnlyPkgs` -- upstream's companion to
          # passing `nixpkgs.pkgs` -- is deliberately NOT imported here. It
          # replaces the whole nixpkgs module and turns `nixpkgs.overlays`
          # into a hard error (types.unique), but this builder BLESSES
          # module-level `nixpkgs.overlays`: nixpkgs composes them onto the
          # injected set via `cfg.pkgs.appendOverlays cfg.overlays` (see
          # the NOTE below, pinned by the module-level-overlay-applies
          # test), and third-party modules bringing their own overlays rely
          # on exactly that. What readOnlyPkgs would guard beyond overlays
          # is covered without it: `nixpkgs.config` hard-fails nixpkgs' own
          # assertion, and hostPlatform/buildPlatform definitions get the
          # warnings below instead of being silently ignored.
          (
            { config, options, ... }:
            {
              _file = ../mk-nixos-system.nix;
              networking.hostName = lib.mkDefault hostname;
              # mkBuilderDefault (see ./priorities.nix), not mkDefault: a
              # module's own mkDefault definition would otherwise sit at
              # EQUAL priority and collide with this pin instead of
              # winning it (and then being warned about below)
              nixpkgs.hostPlatform = mkBuilderDefault system;
              # host tags label the boot entry too -- the MERGED option value,
              # so tags contributed by modules land there as well; a host
              # setting the option itself overrides this
              system.nixos.tags = lib.mkDefault config.nixpkgsLibExtensions.tags;
              # NOTE: this used to warn that module-level nixpkgs.overlays /
              # nixpkgs.config are ignored because the builder provides
              # `pkgs`. That was WRONG. Passing `pkgs` as an eval-config
              # ARGUMENT sets the `nixpkgs.pkgs` option
              # (nixos/lib/eval-config.nix), and the nixpkgs module then
              # builds `cfg.pkgs.appendOverlays cfg.overlays`
              # (nixos/modules/misc/nixpkgs.nix) -- so a module's overlays
              # compose on top of ours as usual. `nixpkgs.config` is not
              # silently dropped either: nixpkgs asserts it must be empty
              # when pkgs is passed in, which is why `nixpkgsConfig` is the
              # only route for THAT one. (The nixpkgs warning about ignored
              # options applies to `specialArgs.pkgs`, which this builder
              # deliberately does not use -- see internal/context.nix.)
              #
              # The PLATFORM options genuinely are ignored with `pkgs`
              # injected, so a module defining one deserves a word.
              # Detected by definition PRIORITY, not isDefined: an option
              # DEFAULT registers as an (mkOptionDefault) definition too,
              # so anything beating the builder's own pin above
              # (builderDefaultPriority, for hostPlatform) or the option
              # default (for buildPlatform; upstream's hasBuildPlatform
              # does the same) is a foreign definition -- a module's plain
              # or mkDefault definition alike.
              warnings =
                lib.optional (options.nixpkgs.hostPlatform.highestPrio < builderDefaultPriority)
                  "mkNixosSystem: host `${hostname}`: a module sets `nixpkgs.hostPlatform`, which is IGNORED: the builder passes an externally built package set (`nixpkgs.pkgs`), whose platform comes from the builder's `system` argument. Set that argument instead."
                ++
                  lib.optional (options.nixpkgs.buildPlatform.highestPrio < (lib.mkOptionDefault null).priority)
                    "mkNixosSystem: host `${hostname}`: a module sets `nixpkgs.buildPlatform`, which is IGNORED: the builder passes an externally built package set (`nixpkgs.pkgs`), and nixpkgs derives both platforms from it. Cross-compile by giving the builder a `nixpkgs`/`system` combination that builds the package set you mean.";
            }
          )
          bootstrapModule
          systemHomesModule
        ]
        ++ autoNixosModules
        ++ autoHostModules
        ++ modules
        ++ perUserModules
        ++ userNixosConfigs;
      };
    in
    # Returned BARE (like mkHomeConfiguration): assign it to
    # `nixosConfigurations.<hostname>` yourself, or let
    # buildNixosConfigurations key a whole set of hosts.
    #
    # Two evaluation routes:
    # - UNPATCHED nixpkgs flake (the common case): `nixpkgs.lib.nixosSystem`,
    #   the entry point nixpkgs maintains for flakes. It injects
    #   `nixpkgs.flake.source`, so registry/NIX_PATH pinning (`nix run
    #   nixpkgs#hello`, `<nixpkgs>`) resolves to the exact tree the system
    #   was built from -- a raw eval-config import silently loses that.
    # - PATCHED tree (or a `nixpkgs` input exposing no lib.nixosSystem):
    #   the standard workaround -- eval-config imported from the SELECTED
    #   tree -- plus an explicit `nixpkgs.flake.source` pointing at that
    #   tree, so the pinning follows the patched source too.
    if !nixpkgsPatched && (nixpkgsInput.lib or { }) ? nixosSystem then
      nixpkgsInput.lib.nixosSystem evalArgs
    else
      import (selectedSrc + "/nixos/lib/eval-config.nix") (
        evalArgs
        // {
          # eval-config's `system` DEFAULT is builtins.currentSystem; null
          # removes that impure entry point (hostPlatform is set above),
          # exactly as lib.nixosSystem does
          system = null;
          modules = evalArgs.modules ++ [
            {
              _file = ../mk-nixos-system.nix;
              # what lib.nixosSystem would have injected, pointed at the
              # selected tree (string coercion: selectedSrc may be the
              # applyPatches derivation)
              nixpkgs.flake.source = "${selectedSrc}";
            }
          ];
        }
      );
}
