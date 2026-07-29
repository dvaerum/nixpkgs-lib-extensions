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
      tags = [ "default-tag" ];
    };
    defhost = { };
    overridehost = {
      tags = [ "host-tag" ];
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
    && built.defhost._module.specialArgs.tags == [ "default-tag" ];

  # per-argument merge, host wins entirely
  defaults-host-override-wins = built.overridehost._module.specialArgs.tags == [ "host-tag" ];

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

  # _defaults is an ALLOWLIST: a typo'd key throws instead of being
  # silently dropped by the builder's `...` pattern
  defaults-typo-key-throws = throws (myLib.buildNixosConfigurations {
    _defaults = {
      homeConfiguration = { };
    };
    h = { };
  });
  # ... and the additional* special-case fires for unknown names too
  defaults-additional-prefix-throws = throws (myLib.buildNixosConfigurations {
    _defaults = {
      additionalOverlays = [ ];
    };
    h = { };
  });

  # host entries are allowlisted too: a leftover argument (the removed
  # `users`) or a typo throws instead of silently doing nothing
  host-unknown-key-throws = throws (myLib.buildNixosConfigurations {
    h = {
      users = [ "root" ];
    };
  });

  # buildHomeConfigurations: the SAME hosts attrset produces the merged
  # "user@host" set across all hosts, with per-host registry overrides
  build-home-configurations =
    let
      homes = myLib.buildHomeConfigurations {
        _defaults = {
          inherit inputs system;
          homeConfigurations."alice" = exampleDir + "/users/alice";
          # nixos-only argument: must be accepted and ignored here
          modules = [ ];
        };
        hostA = { };
        hostB = {
          homeConfigurations."bob@hostB" = exampleDir + "/users/bob";
        };
      };
    in
    homes ? "alice@hostA" && homes ? "bob@hostB" && !(homes ? "alice@hostB");

  # ... and shares the validation: the same typo throws there too
  build-home-configurations-allowlisted = throws (myLib.buildHomeConfigurations {
    h = {
      users = [ "root" ];
    };
  });
}
