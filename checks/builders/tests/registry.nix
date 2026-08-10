# The userRegistry registry: user derivation from keys, the
# "<user>@<host>" / "<user>@*" / "<user>" resolution rules, companion
# configuration.nix handling and entry validation.
{
  lib,
  myLib,
  inputs,
  system,
  example,
  laptop,
  server,
  homesThrow,
  exampleDir,
  fixturesDir,
  invalidFixturesDir,
  repoDir,
  ...
}:
{
  users-derived-from-registry =
    laptop.config.nixpkgsLibExtensions.users == [
      "alice"
      "bob"
      "dave"
      "eve"
      "frank"
      "grace"
    ];

  # companion configuration.nix files from user directories reach the system
  companion-config-applied = laptop.config.users.groups ? media;
  system-only-user-config-applied = laptop.config.users.groups ? backup-operators;

  # "frank@*" and "frank@laptop" MERGE: both configuration.nix apply
  wildcard-config-applied = laptop.config.users.groups ? vpn;
  wildcard-merges-with-host-entry = laptop.config.users.groups ? scanner;

  # a plain entry shadowed by "<user>@*" must NOT apply (and warns). Built
  # here rather than in the example: the warning fires on every evaluation
  # of whatever registry contains it, and the example doubles as the
  # `nix flake init` template, where four warnings on a first build look
  # like something is broken. The shadowed directory lives in
  # checks/fixtures/ for the same reason: only this probe references it,
  # and the template should not ship an unreferenced user directory.
  shadowed-plain-entry-ignored =
    !(
      (myLib.mkNixosSystem {
        inherit inputs system;
        hostname = "shadowprobe";
        modules = [ (exampleDir + "/hosts/server/configuration.nix") ];
        userRegistry = {
          "grace@*" = exampleDir + "/users/grace-base";
          "grace" = fixturesDir + "/grace-plain";
        };
      }).config.users.groups ? grace-legacy
    );

  # ── entry validation ──
  invalid-entry-throws = homesThrow {
    "bad" = {
      some = "module";
    };
  };
  empty-directory-throws = homesThrow { "bad" = invalidFixturesDir + "/no-nix-files"; };
  missing-path-throws = homesThrow { "bad" = exampleDir + "/does-not-exist"; };
  # absolute string paths still work like path literals (forcing this
  # probe emits the string-path warning below -- deliberate: warned, not
  # removed)
  string-path-entry-works =
    builtins.attrNames (
      myLib.buildHomeConfigurations {
        laptop = {
          inherit inputs system;
          userRegistry."alice" = "${exampleDir + "/users/alice"}";
          loginHomes = [ "alice" ];
        };
      }
    ) == [ "alice@laptop" ];
  # ... but they are a pure-eval hazard, so the entry WARNS. A warning is
  # not observable in-language (tryEval only catches throws), so the
  # message is exported as data and its text pinned here: it must name the
  # hazard and the fix
  string-path-entry-warning-text =
    let
      registry = import (repoDir + "/lib/nixos/internal/registry.nix") {
        inherit lib;
        self = myLib;
      };
      msg = registry.stringPathEntryWarning "alice" "/somewhere/users/alice";
    in
    lib.hasInfix "pure evaluation" msg && lib.hasInfix "path value" msg && lib.hasInfix "`alice`" msg;

  # only loginHomes get homeConfigurations outputs: dave/frank/grace are
  # system-managed, eve has no home config at all
  home-configs-keyed-per-host =
    builtins.attrNames example.homeConfigurations == [
      "alice@laptop"
      "bob@laptop"
    ];

  # key forms resolved on a second host: wildcard + plain apply, the
  # laptop-only entry does not
  wildcard-applies-on-any-host =
    builtins.attrNames (
      myLib.buildHomeConfigurations {
        server = {
          inherit inputs system;
          userRegistry = {
            "alice" = exampleDir + "/users/alice"; # plain -> any host
            "bob@laptop" = exampleDir + "/users/bob"; # laptop only -> NOT on server
            "frank@*" = exampleDir + "/users/frank-base"; # wildcard -> every host
          };
          loginHomes = [
            "alice"
            "bob"
            "frank"
          ];
        };
      }
    ) == [
      "alice@server"
      "frank@server"
    ];

  # the server has no registry: no users
  server-no-users = server.config.nixpkgsLibExtensions.users == [ ];

  # a plain entry still applies when the user's only @-entries target OTHER
  # hosts (shadowing needs a matching @-entry, not any @-entry)
  plain-applies-despite-foreign-host-entry =
    builtins.attrNames (
      myLib.buildHomeConfigurations {
        laptop = {
          inherit inputs system;
          userRegistry = {
            "helen" = exampleDir + "/users/alice";
            "helen@otherhost" = exampleDir + "/users/bob";
          };
          loginHomes = [ "helen" ];
        };
      }
    ) == [ "helen@laptop" ];

  # an explicit null registry behaves like an empty one
  null-registry-disables =
    let
      sys = (
        myLib.mkNixosSystem {
          inherit inputs system;
          hostname = "nullreg";
          modules = [ (exampleDir + "/hosts/server/configuration.nix") ];
          userRegistry = null;
        }
      );
    in
    sys.config.nixpkgsLibExtensions.users == [ ]
    && !(sys.config.systemd.user.services ? home-manager-bootstrap);

  # ── registry keys that cannot match anything ──
  # `"alice@"` was dropped by usersFromRegistry (its host part matches no
  # host and not `*`) while registryUserNames kept `alice`, so the two
  # parsers disagreed: loginHomes = [ "alice" ] passed validation for a user
  # no host had, and the system built and booted WITHOUT the user.
  registry-key-empty-host-throws =
    !(builtins.tryEval (
      builtins.attrNames (
        myLib.buildNixosConfigurations {
          h = {
            inherit inputs system;
            userRegistry."alice@" = exampleDir + "/users/alice";
            loginHomes = [ "alice" ];
          };
        }
      )
    )).success;

  # `"@laptop"` is the mirror image: it produced a real account named "",
  # a group named "", and (via declareZfsRootDisk) a dataset `HOME/`
  registry-key-empty-user-throws =
    !(builtins.tryEval (
      builtins.attrNames (
        myLib.buildNixosConfigurations {
          laptop = {
            inherit inputs system;
            userRegistry."@laptop" = exampleDir + "/users/alice";
          };
        }
      )
    )).success;

  # ... while the legitimate forms keep working
  registry-key-forms-still-accepted =
    (myLib.buildNixosConfigurations {
      laptop = {
        inherit inputs system;
        userRegistry = {
          "alice" = exampleDir + "/users/alice";
          "bob@laptop" = exampleDir + "/users/bob";
          "frank@*" = exampleDir + "/users/frank-base";
        };
      };
    }).laptop.config.nixpkgsLibExtensions.users == [
      "alice"
      "bob"
      "frank"
    ];
}
