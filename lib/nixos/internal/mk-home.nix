# PRIVATE, per the calling convention documented in ./shared.nix.
#
# `mkHome` is the mkHomeConfiguration implementation, with the same
# explicit `core` parameter as ./mk-system.nix -- see the note there.
{ lib, self, ... }:
let
  inherit (import ./context.nix { inherit lib self; }) mkContext;
  inherit (import ./ext-options.nix { inherit lib self; })
    extHomeOptionsModule
    homeStateVersionModule
    ;
  inherit (import ./registry.nix { inherit lib self; })
    resolveUser
    usersFromRegistry
    resolveUsers
    loginFlakeRefSources
    ;
in
{
  mkHome =
    core:
    {
      inputs,
      hostname ? null,
      system,
      username,
      homeModules ? [ ],
      tags ? [ ],
      group ? null,
      ...
    }@args:
    let
      ctx = mkContext core args;
      inherit (ctx)
        lib
        pkgs
        mySpecialArguments
        home-manager
        autoHomeModules
        ;

      # The users tree: scanned from `loginFlakeRef` when the homes live
      # in another flake (loginFlakeRefSources handles its null/list/
      # replace forms the same way mk-system.nix does), else `rootPath`
      # (this flake). `usersTree` may also be handed in already-resolved
      # by a plan, which is how a fleet shares one scan across every host
      # and home. A home.nix never gets configuration.nix's NixOS module
      # authority, so the trust dimension (untrustedUsers) is meaningless
      # here -- only `.tree` is used.
      userTree =
        (
          if args ? usersTree then
            args.usersTree
          else
            resolveUsers {
              sources = loginFlakeRefSources (args.loginFlakeRef or null) (
                args.rootPath or (inputs.self or null)
              );
              label = if hostname == null then "${username}" else "${username}@${hostname}";
              traceDiscoveredUsers = args.traceDiscoveredUsers or true;
            }
        ).tree;
      registryHomeModules = (resolveUser userTree hostname username).homeModules;
    in
    (
      if home-manager == null then
        throw ''
          mkHomeConfiguration: no home-manager input found (detected
          by capability: an input whose `lib` has `homeManagerConfiguration`).
        ''
      else if registryHomeModules == [ ] then
        throw ''
          mkHomeConfiguration: `${username}` has no home.nix in the users
          tree${
            if hostname == null then "" else " for host `${hostname}`"
          } (no such user directory, or a system-only one shipping just a
          configuration.nix).
        ''
      else
        home-manager.lib.homeManagerConfiguration {
          # `lib` explicitly: home-manager re-fixes the module lib via
          # lib.extend, so it must start from the context lib (extLib,
          # input lib overlays and namespaced input libs are all inside its
          # fixed point) -- with the default pkgs.lib the namespaced input
          # libs would be lost in that re-fix
          inherit pkgs lib;
          extraSpecialArgs = mySpecialArguments;
          modules =
            autoHomeModules
            ++ homeModules
            # every matched home.nix: the user's own, plus their
            # hosts/<hostname> override when this home is built for a host
            ++ registryHomeModules
            ++ [
              # the same `nixpkgsLibExtensions.*` options a SYSTEM-managed
              # home gets via home-manager.sharedModules (mk-system.nix)
              (extHomeOptionsModule {
                inherit hostname group tags;
                users = usersFromRegistry userTree hostname;
                inherit (ctx) inputPkgs channels;
              })
              # home.stateVersion default (current release) -- with a
              # warning for any home that RELIES on it
              (homeStateVersionModule hostname)
              # scheduled refresh from a LIVE ref. STANDALONE homes only
              # -- mk-system.nix injects the same module for its
              # system-managed homes with `systemManaged = true`, which
              # declares the options (one home.nix is evaluated by both
              # mechanisms) but produces no unit.
              # `loginFlakeRef` is deliberately NOT reused as a fallback
              # here, despite naming the same repo in the obvious setup:
              # a flake INPUT is an immutable /nix/store path (can never
              # pick up a new commit), and the one shape that IS live --
              # a bare string -- cannot be scanned for users at all, so a
              # home built that way does not exist to carry a timer.
              (self.homeManagerAutoUpgradeModule {
                enable = args.homeAutoUpgrade or true;
                flakeRef = args.homeAutoUpgradeFlakeRef or null;
                homeManagerPackage = home-manager.packages.${system}.home-manager or null;
              })
              {
                _file = ../mk-home-configuration.nix;
                home.username = lib.mkDefault username;
                home.homeDirectory = lib.mkDefault "/home/${username}";
                # `username` stays a per-home module argument, like the
                # system-managed mechanism wires it (extraSpecialArgs cannot
                # vary per user there; _module.args can)
                _module.args.username = username;
              }
            ];
        }
    );
}
