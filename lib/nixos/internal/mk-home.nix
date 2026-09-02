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
      # in another flake, else `rootPath` (this flake). `users` may also
      # be handed in already-resolved by a plan, which is how a fleet
      # shares one scan across every host and home.
      userTree =
        if args ? usersTree then
          args.usersTree
        else
          resolveUsers {
            ref = args.loginFlakeRef or (args.rootPath or (inputs.self or null));
            label = if hostname == null then "${username}" else "${username}@${hostname}";
            traceDiscoveredUsers = args.traceDiscoveredUsers or true;
          };
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
