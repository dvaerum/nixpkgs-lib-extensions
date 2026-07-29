# buildNixosConfigurations `_defaults`: shared arguments for every host,
# per-argument host override, the layered pairs (modules/additionalModules,
# specialArgs/additionalSpecialArgs) and the forbidden-key throws.
{
  myLib,
  inputs,
  system,
  exampleDir,
  ...
}:
let
  built = myLib.buildNixosConfigurations {
    _defaults = {
      inherit inputs system;
      modules = [
        (exampleDir + "/hosts/server/configuration.nix")
        { users.groups.from-defaults-module = { }; }
      ];
      specialArgs = {
        fromDefaults = "d";
        layered = "base";
      };
      desktopEnvironment = "gnome";
    };
    defhost = { };
    overridehost = {
      desktopEnvironment = "plasma";
      additionalModules = [ { users.groups.from-additional-module = { }; } ];
      additionalSpecialArgs = {
        fromHost = "h";
        layered = "host";
      };
    };
  };

  throws = expr: !(builtins.tryEval (builtins.attrNames expr)).success;
in
{
  # _defaults reach every host: its modules and specialArgs are in effect
  # on a host that sets nothing of its own
  defaults-applied =
    built.defhost.config.users.groups ? from-defaults-module
    && built.defhost._module.specialArgs.fromDefaults == "d"
    && built.defhost._module.specialArgs.desktopEnvironment == "gnome";

  # per-argument merge, host wins entirely
  defaults-host-override-wins = built.overridehost._module.specialArgs.desktopEnvironment == "plasma";

  # the layered pair: _defaults.modules plus the host's additionalModules
  # both apply
  defaults-modules-layering =
    built.overridehost.config.users.groups ? from-defaults-module
    && built.overridehost.config.users.groups ? from-additional-module;

  # same for specialArgs/additionalSpecialArgs; on a key conflict the
  # host's additionalSpecialArgs wins
  defaults-special-args-layering =
    built.overridehost._module.specialArgs.fromDefaults == "d"
    && built.overridehost._module.specialArgs.fromHost == "h"
    && built.overridehost._module.specialArgs.layered == "host";

  # _defaults must not set hostname (comes from the key) or the
  # per-host halves of the layered pairs
  defaults-hostname-throws = throws (myLib.buildNixosConfigurations {
    _defaults = { hostname = "x"; };
    h = { };
  });
  defaults-additional-modules-throws = throws (myLib.buildNixosConfigurations {
    _defaults = {
      additionalModules = [ ];
    };
    h = { };
  });
  defaults-additional-special-args-throws = throws (myLib.buildNixosConfigurations {
    _defaults = {
      additionalSpecialArgs = { };
    };
    h = { };
  });
}
