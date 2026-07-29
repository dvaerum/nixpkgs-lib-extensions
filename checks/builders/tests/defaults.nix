# buildNixosConfigurations `_defaults`: shared arguments for every host,
# per-argument host override, the layered pairs (modules/additionalModules,
# specialArgs/additionalSpecialArgs) and the forbidden-key throws.
{
  lib,
  myLib,
  inputs,
  system,
  exampleDir,
  repoDir,
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
  # "user@host" set across all hosts, with per-host registry overrides;
  # only loginUsers get outputs
  build-home-configurations =
    let
      homes = myLib.buildHomeConfigurations {
        _defaults = {
          inherit inputs system;
          userRegistry."alice" = exampleDir + "/users/alice";
          loginUsers = [
            "alice"
            "bob"
          ];
          # nixos-only argument: must be accepted and ignored here
          modules = [ ];
        };
        hostA = { };
        hostB = {
          userRegistry = {
            "bob@hostB" = exampleDir + "/users/bob";
            # present but NOT a login user on hostB: no output
            "dave" = exampleDir + "/users/dave";
          };
          loginUsers = [ "bob" ];
        };
      };
    in
    homes ? "alice@hostA" && homes ? "bob@hostB" && !(homes ? "alice@hostB") && !(homes ? "dave@hostB");

  # ... and shares the validation: the same typo throws there too
  build-home-configurations-allowlisted = throws (myLib.buildHomeConfigurations {
    h = {
      users = [ "root" ];
    };
  });

  # DIRECT builder calls are validated too: the `...` patterns no longer
  # swallow typos or stale argument names
  direct-nixos-call-typo-throws =
    !(builtins.tryEval (
      builtins.seq (myLib.nixosConfigurationsBuilder {
        inherit inputs system;
        hostname = "typo";
        users = [ "root" ];
      }) true
    )).success;
  direct-home-call-typo-throws =
    !(builtins.tryEval (
      builtins.seq (myLib.homeConfigurationsBuilder {
        inherit inputs system;
        hostname = "laptop";
        username = "alice";
        userRegistry."alice" = exampleDir + "/users/alice";
        homesharedmodules = [ ];
      }) true
    )).success;

  # CONTEXT SHARING is observably equivalent: in a buildNixosConfigurations
  # set, a host overriding no core argument reuses the `_defaults` context
  # core, a host overriding one (nixpkgsConfig) gets its own -- the
  # overriding host's pkgs must reflect its override while the sharing
  # host matches a directly-built reference (which never sees `_core`).
  defaults-core-sharing-equivalence =
    let
      built = myLib.buildNixosConfigurations {
        _defaults = {
          inherit inputs system;
        };
        # overrides no core argument (tags is per-host layer): shares the core
        plainhost = {
          tags = [ "shared-core" ];
        };
        # overrides a core argument: must get its own context
        cudahost = {
          nixpkgsConfig.cudaSupport = true;
        };
      };
      reference = myLib.nixosConfigurationsBuilder {
        inherit inputs system;
        hostname = "plainhost";
        tags = [ "shared-core" ];
      };
    in
    built.cudahost.pkgs.config.cudaSupport
    && !built.plainhost.pkgs.config.cudaSupport
    && !reference.pkgs.config.cudaSupport
    && built.plainhost._module.specialArgs.hostname == "plainhost"
    && built.cudahost._module.specialArgs.hostname == "cudahost"
    && built.plainhost._module.specialArgs.tags == reference._module.specialArgs.tags;

  # the allowlist and its documentation cannot drift: every allowlisted
  # name must appear backtick-quoted in the buildNixosConfigurations doc
  # comment (this is exactly the drift that happened with the loginUsers
  # renames)
  allowlist-documented =
    let
      doc = builtins.readFile (repoDir + "/lib/nixos/buildNixosConfigurations.nix");
      shared = import (repoDir + "/lib/nixos/internal/shared.nix") myLib;
    in
    builtins.all (n: lib.hasInfix "`${n}`" doc) shared.allowedDefaultArgs;
}
