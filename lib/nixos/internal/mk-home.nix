# PRIVATE (not listed in lib/default.nix). Takes the one calling convention: `self` is the
# fully assembled nixpkgs-lib-extensions lib (a fixed point), `lib` is nixpkgs'.
#
# `mkHome` is the homeConfigurationsBuilder implementation, with the same
# explicit `core` parameter as ./mk-system.nix -- see the note there.
{ lib, self, ... }:
let
  inherit (import ./context.nix { inherit lib self; }) mkContext;
  inherit (import ./registry.nix { inherit lib self; }) resolveUser usersFromRegistry;
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

      registry = if userRegistry == null then { } else userRegistry;
      registryHomeModules = (resolveUser registry hostname username).homeModules;
    in
    (
      if home-manager == null then
        throw ''
          homeConfigurationsBuilder: no home-manager input found (detected
          by capability: an input whose `lib` has `homeManagerConfiguration`).
        ''
      else if registryHomeModules == [ ] then
        throw ''
          homeConfigurationsBuilder: `${username}` has no home.nix in
          `userRegistry` matching host `${hostname}` (unmatched keys,
          or a system-only entry shipping just a configuration.nix).
        ''
      else
        home-manager.lib.homeManagerConfiguration {
          # `lib` explicitly: home-manager re-fixes the module lib via
          # lib.extend, so it must start from the context lib (extLib,
          # input extendLibs and namespaced input libs are all inside its
          # fixed point) -- with the default pkgs.lib the namespaced input
          # libs would be lost in that re-fix
          inherit pkgs lib;
          extraSpecialArgs = mySpecialArguments // {
            inherit username;
            listOfUsernames = usersFromRegistry registry hostname;
          };
          modules =
            autoHomeModules
            ++ homeModules
            # all matched home.nix files: "<user>@*" and "<user>@<host>" merge
            ++ registryHomeModules
            ++ [
              {
                _file = ../homeConfigurationsBuilder.nix;
                home.username = lib.mkDefault username;
                home.homeDirectory = lib.mkDefault "/home/${username}";
                home.stateVersion = lib.mkDefault lib.trivial.release;
              }
            ];
        }
    );
}
