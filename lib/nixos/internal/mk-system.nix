# PRIVATE (not listed in lib/default.nix). Takes the one calling convention: `self` is the
# fully assembled nixpkgs-lib-extensions lib (a fixed point), `lib` is nixpkgs'.
#
# `mkSystem` is the nixosConfigurationsBuilder implementation with the
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
  inherit (import ./registry.nix { inherit lib self; })
    resolveUser
    usersFromRegistry
    usersWithHome
    ;
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
      tags ? [ ],
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
        ;

      registry = if userRegistry == null then { } else userRegistry;

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
      systemUsersWithHome = builtins.filter (u: !(builtins.elem u loginHomes)) (
        usersWithHome registry hostname
      );
      hmNixosModule =
        if home-manager == null then
          null
        else
          home-manager.nixosModules.default or home-manager.nixosModules.home-manager or null;
      # Users would be getting NOTHING for their home.nix -- fail loudly
      # instead of silently building a homeless system.
      wantSystemHomes =
        if systemUsersWithHome != [ ] && hmNixosModule == null then
          lib.warn "nixosConfigurationsBuilder: host `${hostname}`: user(s) ${builtins.concatStringsSep ", " systemUsersWithHome} have a home.nix, but no home-manager input (or none exposing a NixOS module) exists -- their SYSTEM-managed homes are NOT built. Add a home-manager input, or move them to loginHomes." false
        else
          systemUsersWithHome != [ ] && hmNixosModule != null;
      systemHomesModule = {
        _file = ../nixosConfigurationsBuilder.nix;
        imports = lib.optional wantSystemHomes (
          { ... }:
          {
            imports = [ hmNixosModule ];
            home-manager = {
              # the system's package set, not a second nixpkgs eval;
              # both mkDefault: override in your own modules if needed
              useGlobalPkgs = lib.mkDefault true;
              useUserPackages = lib.mkDefault true;
              extraSpecialArgs = mySpecialArguments // {
                listOfUsernames = users;
              };
              sharedModules =
                autoHomeModules
                ++ homeModules
                ++ [
                  {
                    _file = ../nixosConfigurationsBuilder.nix;
                    home.stateVersion = lib.mkDefault lib.trivial.release;
                  }
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
      # when `hostGroup` is set, grouped one level deeper under
      # hosts/<hostGroup>/.
      autoHostModules =
        let
          hostsDir =
            mySpecialArguments.rootPath
            + (
              if mySpecialArguments.hostGroup == null then "/hosts" else "/hosts/${mySpecialArguments.hostGroup}"
            );
          file = hostsDir + "/${hostname}.nix";
          dir = hostsDir + "/${hostname}/configuration.nix";
          fileExists = builtins.pathExists file;
          dirExists = builtins.pathExists dir;
        in
        if fileExists && dirExists then
          throw ''
            nixosConfigurationsBuilder: host `${hostname}` has both
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
    # Returned BARE (like homeConfigurationsBuilder): assign it to
    # `nixosConfigurations.<hostname>` yourself, or let
    # buildNixosConfigurations key a whole set of hosts.
    (import "${selectedSrc}/nixos/lib/eval-config.nix" {
      inherit system lib pkgs;
      specialArgs = mySpecialArguments // {
        listOfUsernames = users;
      };
      modules = [
        (
          { ... }:
          {
            _file = ../nixosConfigurationsBuilder.nix;
            networking.hostName = lib.mkDefault hostname;
            # host tags label the boot entry too; a host setting the
            # option itself overrides this
            system.nixos.tags = lib.mkDefault tags;
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
    });
}
