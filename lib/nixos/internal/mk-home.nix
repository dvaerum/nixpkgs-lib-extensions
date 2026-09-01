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
    resolveUserRegistry
    ;
in
{
  mkHome =
    core:
    {
      inputs,
      hostname,
      system,
      username,
      userRegistry ? { },
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

      # loginFlakeRef/traceDiscoveredUsers are not this function's OWN
      # arguments (a direct mkHomeConfiguration call has no login-bootstrap
      # concept to auto-discover from) -- they only arrive here via the
      # hosts-attrset path (homesFromPlan passes the host's full merged
      # args), where the SAME resolution hosts-args.nix/mk-system.nix
      # already ran must reach a login-managed user's OWN home too, or a
      # user that only exists via auto-discovery would build no home.nix
      # for anyone.
      registry = resolveUserRegistry {
        wasGiven = args ? userRegistry;
        inherit userRegistry inputs hostname;
        loginFlakeRef = args.loginFlakeRef or null;
        traceDiscoveredUsers = args.traceDiscoveredUsers or true;
      };
      registryHomeModules = (resolveUser registry hostname username).homeModules;
    in
    (
      if home-manager == null then
        throw ''
          mkHomeConfiguration: no home-manager input found (detected
          by capability: an input whose `lib` has `homeManagerConfiguration`).
        ''
      else if registryHomeModules == [ ] then
        throw ''
          mkHomeConfiguration: `${username}` has no home.nix in
          `userRegistry` matching host `${hostname}` (unmatched keys,
          or a system-only entry shipping just a configuration.nix).
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
            # all matched home.nix files: "<user>@*" and "<user>@<host>" merge
            ++ registryHomeModules
            ++ [
              # the same `nixpkgsLibExtensions.*` options a SYSTEM-managed
              # home gets via home-manager.sharedModules (mk-system.nix)
              (extHomeOptionsModule {
                inherit hostname group tags;
                users = usersFromRegistry registry hostname;
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
