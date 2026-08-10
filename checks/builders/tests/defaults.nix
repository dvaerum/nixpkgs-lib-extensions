# buildNixosConfigurations `_defaults`: shared arguments for every host,
# per-argument host override, the `extra` layering slot and the
# forbidden-key throws.
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
      extra = {
        modules = [ { users.groups.from-additional-module = { }; } ];
        specialArgs = {
          fromHost = "h";
          layered = "host";
        };
      };
    };
  };

  throws = expr: !(builtins.tryEval (builtins.attrNames expr)).success;

  shared = import (repoDir + "/lib/nixos/internal/shared.nix") {
    inherit lib;
    self = myLib;
  };
  # `throws` alone cannot say WHICH error fired -- tryEval discards the
  # message, so an unrelated failure elsewhere in the expression satisfies
  # it just as well. These assert on the complaint itself.
  complains =
    hosts: infix:
    let
      problems = shared.hostsProblems "probe" hosts;
    in
    builtins.any (p: lib.hasInfix infix p) problems;
in
{
  # _defaults reach every host: its modules and specialArgs are in effect
  # on a host that sets nothing of its own
  defaults-applied =
    built.defhost.config.users.groups ? from-defaults-module
    && built.defhost._module.specialArgs.fromDefaults == "d"
    && built.defhost.config.nixpkgsLibExtensions.tags == [ "default-tag" ];

  # per-argument merge, host wins entirely
  defaults-host-override-wins = built.overridehost.config.nixpkgsLibExtensions.tags == [ "host-tag" ];

  # `extra.modules` ADDS to _defaults.modules rather than replacing it
  defaults-modules-layering =
    built.overridehost.config.users.groups ? from-defaults-module
    && built.overridehost.config.users.groups ? from-additional-module;

  # same for extra.specialArgs; on a key conflict the host's addition wins
  defaults-special-args-layering =
    built.overridehost._module.specialArgs.fromDefaults == "d"
    && built.overridehost._module.specialArgs.fromHost == "h"
    && built.overridehost._module.specialArgs.layered == "host";

  # _defaults must not set hostname (comes from the key) or the
  # per-host halves of the layered pairs
  defaults-hostname-throws = throws (
    myLib.buildNixosConfigurations {
      _defaults = {
        hostname = "x";
      };
      h = { };
    }
  );
  # `extra` is per-host only: `_defaults` holds the base it adds to
  defaults-extra-throws = throws (
    myLib.buildNixosConfigurations {
      _defaults = {
        extra = { };
      };
      h = { };
    }
  );
  # ... and an unknown key inside `extra` is checked like any other
  host-extra-unknown-key-throws = throws (
    myLib.buildNixosConfigurations {
      h = {
        extra.notAnArgument = [ ];
      };
    }
  );
  # every argument can be layered now, not just two -- homeModules could
  # not be extended at all before
  extra-layers-any-argument =
    let
      built = myLib.buildNixosConfigurations {
        _defaults = {
          inherit inputs system;
          modules = [ (exampleDir + "/hosts/server/configuration.nix") ];
          tags = [ "base" ];
        };
        h.extra.tags = [ "host" ];
      };
    in
    built.h.config.nixpkgsLibExtensions.tags == [
      "base"
      "host"
    ];

  # _defaults is an ALLOWLIST: a typo'd key throws instead of being
  # silently dropped by the builder's `...` pattern
  defaults-typo-key-throws = throws (
    myLib.buildNixosConfigurations {
      _defaults = {
        homeConfiguration = { };
      };
      h = { };
    }
  );

  # host entries are allowlisted too: an unknown argument throws instead
  # of silently doing nothing
  host-unknown-key-throws = throws (
    myLib.buildNixosConfigurations {
      h = {
        users = [ "root" ];
      };
    }
  );

  # a `_defaults` TYPO used to become a host of its own AND strip every real
  # host of its shared arguments -- silently, because every `_defaults` key
  # is also a valid host key. All `_`-prefixed keys are reserved now.
  defaults-typo-key-is-reserved = throws (
    myLib.buildNixosConfigurations {
      _default = {
        inherit inputs system;
      };
      h = { };
    }
  );
  # ... and a non-attrset `_defaults` says which key is at fault, instead of
  # dying inside builtins.attrNames with no context
  defaults-non-attrset-throws = throws (
    myLib.buildNixosConfigurations {
      _defaults = [
        "not"
        "an"
        "attrset"
      ];
      h = { };
    }
  );

  # buildHomeConfigurations: the SAME hosts attrset produces the merged
  # "user@host" set across all hosts, with per-host registry overrides;
  # only loginHomes get outputs
  build-home-configurations =
    let
      homes = myLib.buildHomeConfigurations {
        _defaults = {
          inherit inputs system;
          userRegistry."alice" = exampleDir + "/users/alice";
          loginHomes = [
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
          loginHomes = [ "bob" ];
        };
      };
    in
    homes ? "alice@hostA" && homes ? "bob@hostB" && !(homes ? "alice@hostB") && !(homes ? "dave@hostB");

  # buildConfigurations is the two build functions over ONE plan: same
  # hosts attrset in, both flake outputs out. The point is that a flake
  # cannot then export the systems while forgetting the homes the login
  # bootstrap resolves at runtime.
  build-configurations-produces-both =
    let
      hosts = {
        _defaults = {
          inherit inputs system;
          userRegistry."alice" = exampleDir + "/users/alice";
          loginHomes = [ "alice" ];
        };
        hostA = { };
        hostB = { };
      };
      both = myLib.buildConfigurations hosts;
    in
    builtins.attrNames both == [
      "homeConfigurations"
      "nixosConfigurations"
    ]
    &&
      builtins.attrNames both.nixosConfigurations == [
        "hostA"
        "hostB"
      ]
    &&
      builtins.attrNames both.homeConfigurations == [
        "alice@hostA"
        "alice@hostB"
      ]
    # and it agrees with the separate functions, host for host
    &&
      both.nixosConfigurations.hostA.config.networking.hostName == (myLib.buildNixosConfigurations hosts)
      .hostA.config.networking.hostName
    &&
      (both.homeConfigurations."alice@hostA").config.home.username
      == ((myLib.buildHomeConfigurations hosts)."alice@hostA").config.home.username;

  # restating a core argument with the SAME VALUE must still share the
  # defaults' context core: presence alone used to disqualify a host, so
  # `inherit inputs system;` in every entry -- the natural thing to write --
  # silently gave each host its own nixpkgs evaluation
  core-sharing-is-by-value =
    let
      built = myLib.buildNixosConfigurations {
        _defaults = {
          inherit inputs system;
          nixpkgsConfig.cudaSupport = true;
        };
        restated = {
          # identical values, spelled out again
          inherit inputs system;
        };
        different = {
          nixpkgsConfig.cudaSupport = false;
        };
      };
    in
    built.restated.pkgs.config.cudaSupport && !built.different.pkgs.config.cudaSupport;

  # cross-mechanism partition: ONE hosts attrset feeds BOTH build
  # functions -- where alice is a login user (hostA) she gets the flake
  # output and NO system home; where she is not (hostB) she gets the
  # system home and no output
  cross-mechanism-partition =
    let
      hosts = {
        _defaults = {
          inherit inputs system;
          userRegistry."alice" = exampleDir + "/users/alice";
        };
        hostA = {
          loginHomes = [ "alice" ];
        };
        hostB = { };
      };
      homes = myLib.buildHomeConfigurations hosts;
      systems = myLib.buildNixosConfigurations hosts;
    in
    builtins.attrNames homes == [ "alice@hostA" ]
    && systems.hostB.config.home-manager.users ? alice
    # hostA has no system-managed homes at all, so the builder never even
    # imports home-manager's NixOS module there
    && !(systems.hostA.options ? home-manager);

  # ... and shares the validation: the same typo throws there too
  build-home-configurations-allowlisted = throws (
    myLib.buildHomeConfigurations {
      h = {
        users = [ "root" ];
      };
    }
  );

  # DIRECT builder calls are validated too: the `...` patterns no longer
  # swallow typos or stale argument names
  direct-nixos-call-typo-throws =
    !(builtins.tryEval (
      builtins.seq (myLib.mkNixosSystem {
        inherit inputs system;
        hostname = "typo";
        users = [ "root" ];
      }) true
    )).success;
  direct-home-call-typo-throws =
    !(builtins.tryEval (
      builtins.seq (myLib.mkHomeConfiguration {
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
  # host matches a directly-built reference (which never sees a plan core).
  # And sharing is per EQUIVALENCE CLASS, not defaults-or-own: two
  # NON-default hosts stating the same override share ONE core between
  # them. Proven by pkgs IDENTITY, not equal-looking config: the probe
  # overlay allocates a fresh lambda per pkgs fixed point, and Nix's `==`
  # only calls two lambdas equal when they are pointer-identical -- so the
  # probe lists compare equal iff both hosts hold the SAME instantiation.
  defaults-core-sharing-equivalence =
    let
      identityProbe = final: prev: { coreSharingProbe = [ (x: x) ]; };
      built = myLib.buildNixosConfigurations {
        _defaults = {
          inherit inputs system;
          overlays = [ identityProbe ];
        };
        # overrides no core argument (tags is per-host layer): shares the core
        plainhost = {
          tags = [ "shared-core" ];
        };
        # override a core argument, TWICE with the same value: one shared
        # core for the class, distinct from the defaults' core
        cudahost = {
          nixpkgsConfig.cudaSupport = true;
        };
        cudahost2 = {
          nixpkgsConfig.cudaSupport = true;
        };
      };
      reference = myLib.mkNixosSystem {
        inherit inputs system;
        hostname = "plainhost";
        tags = [ "shared-core" ];
        overlays = [ identityProbe ];
      };
    in
    built.cudahost.pkgs.config.cudaSupport
    && !built.plainhost.pkgs.config.cudaSupport
    && !reference.pkgs.config.cudaSupport
    && built.plainhost.config.networking.hostName == "plainhost"
    && built.cudahost.config.networking.hostName == "cudahost"
    && built.plainhost.config.nixpkgsLibExtensions.tags == reference.config.nixpkgsLibExtensions.tags
    # the two non-default hosts share one pkgs instantiation ...
    && built.cudahost.pkgs.coreSharingProbe == built.cudahost2.pkgs.coreSharingProbe
    # ... which is NOT the defaults-class instantiation
    && built.plainhost.pkgs.coreSharingProbe != built.cudahost.pkgs.coreSharingProbe;

  # mkContextCore's formals and the shared coreDefaults table cannot drift:
  # every optional core argument except `nixpkgs` (its default is COMPUTED
  # from `inputs`) must take its default from coreDefaults -- a changed
  # default with a stale table makes a host silently share the WRONG core.
  core-defaults-cover-optional-args =
    let
      ctx = import (repoDir + "/lib/nixos/internal/context.nix") {
        inherit lib;
        self = myLib;
      };
      formals = builtins.functionArgs ctx.mkContextCore;
    in
    builtins.filter (n: formals.${n} && n != "nixpkgs") (builtins.attrNames formals)
    == builtins.attrNames ctx.coreDefaults;

  # The core-sharing decision is driven by mkContextCore's own formals
  # (coreArgNames is derived from them), so a parameter added there can
  # never be missing from the list. What the derivation cannot guarantee is
  # that those names are things a host can actually SET: a core parameter
  # outside the builder allowlist never appears in a host entry, so
  # sharesCore would never see it change and every host would share a core
  # built without their value.
  core-args-are-settable-by-hosts =
    let
      shared = import (repoDir + "/lib/nixos/internal/shared.nix") {
        inherit lib;
        self = myLib;
      };
    in
    builtins.all (n: builtins.elem n shared.allowedDefaultArgs) shared.coreArgNames;

  # the allowlist and its documentation cannot drift, in EITHER direction:
  # every allowlisted name must appear as a "- `name`" bullet in the
  # buildNixosConfigurations _defaults reference (a prose mention
  # elsewhere must not satisfy this -- that is exactly the drift that
  # happened with the loginHomes renames), and every bulleted name must
  # still be in the allowlist (a removed argument must take its bullet
  # with it)
  allowlist-documented =
    let
      doc = builtins.readFile (repoDir + "/lib/nixos/build-nixos-configurations.nix");
      shared = import (repoDir + "/lib/nixos/internal/shared.nix") {
        inherit lib;
        self = myLib;
      };
      # the names of every "- `name`" bullet in the doc comment
      bulleted = lib.concatMap (m: if lib.isList m then m else [ ]) (
        builtins.split "- `([a-zA-Z]+)`" doc
      );
    in
    builtins.all (n: builtins.elem n bulleted) shared.allowedDefaultArgs
    && builtins.all (n: builtins.elem n shared.allowedDefaultArgs) bulleted;

  # ── the complaints themselves, not merely "something threw" ──
  # tryEval discards the message, so each of the throws-assertions above is
  # equally satisfied by an unrelated failure. These pin the actual text.
  defaults-hostname-complaint = complains {
    _defaults = {
      hostname = "x";
    };
    h = { };
  } "it comes from each attribute key";
  defaults-typo-complaint = complains {
    _defaults = {
      homeConfiguration = { };
    };
    h = { };
  } "not a builder argument";
  reserved-key-complaint = complains {
    _default = { };
    h = { };
  } "keys starting with `_` are reserved";
  non-attrset-defaults-complaint = complains {
    _defaults = [ "no" ];
    h = { };
  } "must be an attribute set";
  # the host-entry classes are part of the problems DATA too -- they used
  # to be visible only as a throw, so a hosts attrset failing on them
  # reported "no problems" here
  host-typo-complaint = complains { h.users = [ "root" ]; } "Host entries accept";
  host-shape-complaint = complains { h = "not-an-attrset"; } "must be an attribute set";
  host-extra-typo-complaint = complains {
    h.extra.notAnArgument = [ ];
  } "`extra` accepts the same names as `_defaults`";
  hostname-conflict-complaint = complains {
    h.hostname = "other";
  } "The attribute key is the hostname";
  # and the direct-call door reports the offending name too
  direct-call-complaint = builtins.any (p: lib.hasInfix "homesharedmodules" p) (
    shared.builderArgProblems "probe" [ "username" ] {
      inherit inputs system;
      hostname = "x";
      homesharedmodules = [ ];
    }
  );

  # ── `_groups.<name>`: the defaults layer between `_defaults` and the host ──
  # the layer applies to hosts declaring the group, hosts win over it, it
  # wins over `_defaults`, and hosts without a group are untouched
  groups-layer-applies =
    let
      built = myLib.buildNixosConfigurations {
        _defaults = {
          inherit inputs system;
          modules = [ (exampleDir + "/hosts/server/configuration.nix") ];
          tags = [ "default-tag" ];
        };
        _groups.server = {
          tags = [ "server-tag" ];
        };
        web = {
          group = "server";
        };
        override = {
          group = "server";
          tags = [ "host-tag" ];
        };
        plain = { };
      };
    in
    built.web.config.nixpkgsLibExtensions.tags == [ "server-tag" ]
    && built.web.config.nixpkgsLibExtensions.group == "server"
    && built.override.config.nixpkgsLibExtensions.tags == [ "host-tag" ]
    && built.plain.config.nixpkgsLibExtensions.tags == [ "default-tag" ]
    && built.plain.config.nixpkgsLibExtensions.group == null;

  # a group's `extra` ADDS to `_defaults` (like a host's does), and a
  # host's own `extra` then layers on top of the combined value
  groups-extra-layers =
    let
      built = myLib.buildNixosConfigurations {
        _defaults = {
          inherit inputs system;
          modules = [ (exampleDir + "/hosts/server/configuration.nix") ];
          tags = [ "base" ];
        };
        _groups.server.extra.tags = [ "server" ];
        web = {
          group = "server";
          extra.tags = [ "web" ];
        };
      };
    in
    built.web.config.nixpkgsLibExtensions.tags == [
      "base"
      "server"
      "web"
    ];

  # `extra.group` does not exist: nothing about `group` is additive, so a
  # host cannot smuggle a group in through its `extra` slot -- the same
  # rule `_groups.<name>.extra.group` already followed
  host-extra-group-complaint = complains {
    _groups.server = { };
    h.extra.group = "server";
  } "`extra.group` is not a thing";
  host-extra-group-throws = throws (
    myLib.buildNixosConfigurations {
      h = {
        inherit inputs system;
        extra.group = "server";
      };
    }
  );

  # `_defaults.group` opts every host into a layer; a host picks a
  # different one (or none) by overriding `group`
  groups-default-group-applies =
    let
      built = myLib.buildNixosConfigurations {
        _defaults = {
          inherit inputs system;
          modules = [ (exampleDir + "/hosts/server/configuration.nix") ];
          group = "server";
        };
        _groups.server.tags = [ "server-tag" ];
        web = { };
        odd = {
          group = null;
        };
      };
    in
    built.web.config.nixpkgsLibExtensions.tags == [ "server-tag" ]
    && built.odd.config.nixpkgsLibExtensions.tags == [ ];

  # a group layer can carry CORE arguments (nixpkgsConfig, ...): hosts of
  # one group share one context core distinct from the defaults class
  groups-carry-core-args =
    let
      built = myLib.buildNixosConfigurations {
        _defaults = {
          inherit inputs system;
          modules = [ (exampleDir + "/hosts/server/configuration.nix") ];
        };
        _groups.cuda.nixpkgsConfig.cudaSupport = true;
        gpu1 = {
          group = "cuda";
        };
        plain = { };
      };
    in
    built.gpu1.pkgs.config.cudaSupport && !built.plain.pkgs.config.cudaSupport;

  # when `_groups` exists, a host's group must name one of its entries
  groups-unknown-group-throws = throws (
    myLib.buildNixosConfigurations {
      _groups.server = { };
      h = {
        inherit inputs system;
        group = "sever";
      };
    }
  );
  groups-unknown-group-complaint = complains {
    _groups.server = { };
    h.group = "sever";
  } "names no `_groups` entry";
  # ... while WITHOUT `_groups`, `group` stays the free-form
  # classification it always was
  groups-absent-keeps-group-free-form =
    (myLib.buildNixosConfigurations {
      h = {
        inherit inputs system;
        modules = [ (exampleDir + "/hosts/server/configuration.nix") ];
        group = "anything";
      };
    }).h.config.nixpkgsLibExtensions.group == "anything";

  # `_groups` entries are validated like `_defaults` ...
  groups-entry-typo-complaint = complains {
    _groups.server.homeConfiguration = { };
    h = { };
  } "Group entries accept the same names as `_defaults`";
  # ... except `group` itself: a layer cannot re-classify
  groups-entry-group-key-complaint = complains {
    _groups.server.group = "other";
    h = { };
  } "cannot set `group`";
  # ... and their `extra` keys are checked too
  groups-extra-typo-complaint = complains {
    _groups.server.extra.notAnArgument = [ ];
    h = { };
  } "`extra.notAnArgument` is not a builder argument";
  # a non-attrset `_groups` (or entry) is named, not left to die inside
  # builtins.attrNames
  groups-non-attrset-complaint = complains {
    _groups = [ "no" ];
    h = { };
  } "`_groups` must be an attribute set";
  groups-entry-non-attrset-complaint = complains {
    _groups.server = "no";
    h = { };
  } "`_groups.server`: must be an attribute set";
}
