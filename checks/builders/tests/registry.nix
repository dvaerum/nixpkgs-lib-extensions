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
  exampleUsers,
  exampleDir,
  fixturesDir,
  invalidFixturesDir,
  repoDir,
  ...
}:
let
  # A dedicated flake root (checks/fixtures/auto-registry-root) shaped like
  # a real consumer's, with a users/ directory discoverUserRegistry can
  # scan -- distinct from exampleDir, whose users/ has entries
  # (frank-base/frank-laptop) deliberately keyed under a DIFFERENT name
  # than their directory, incompatible with directory-name-derived
  # discovery.
  autoDiscoverRoot = fixturesDir + "/auto-registry-root";
  autoDiscoverInputs = inputs // {
    self = {
      outPath = toString autoDiscoverRoot;
    };
  };
in
{
  # exampleUsers is the ctx-shared canonical list (ext-options.nix
  # compares option values against the same one)
  users-derived-from-registry = laptop.config.nixpkgsLibExtensions.users == exampleUsers;

  # companion configuration.nix files from user directories reach the system
  companion-config-applied = laptop.config.users.groups ? media;
  system-only-user-config-applied = laptop.config.users.groups ? backup-operators;

  # "frank@*" and "frank@laptop" MERGE: both configuration.nix apply
  wildcard-config-applied = laptop.config.users.groups ? vpn;
  wildcard-merges-with-host-entry = laptop.config.users.groups ? scanner;

  # An auto-detected `hosts/<hostname>` subdirectory under a "<user>@*"
  # entry merges in exactly like an explicit "<user>@<hostname>" entry
  # would -- on the matching host, both configuration.nix apply; on any
  # OTHER host, only the "@*" one does.
  autohost-folder-merges-on-matching-host =
    let
      sys = myLib.mkNixosSystem {
        inherit inputs system;
        hostname = "autohostprobe";
        modules = [ (exampleDir + "/hosts/server/configuration.nix") ];
        userRegistry."probe@*" = fixturesDir + "/autohost-user";
      };
    in
    sys.config.users.groups ? autohost-base && sys.config.users.groups ? autohost-override;
  autohost-folder-absent-on-other-host =
    let
      sys = myLib.mkNixosSystem {
        inherit inputs system;
        hostname = "someotherhost";
        modules = [ (exampleDir + "/hosts/server/configuration.nix") ];
        userRegistry."probe@*" = fixturesDir + "/autohost-user";
      };
    in
    sys.config.users.groups ? autohost-base && !(sys.config.users.groups ? autohost-override);
  # An explicit "<user>@<hostname>" key AND an auto-detected `hosts/<hostname>`
  # folder both existing for the same user+host is ambiguous and throws,
  # rather than silently picking a winner.
  autohost-folder-conflicts-with-explicit-entry =
    !(builtins.tryEval (
      (myLib.mkNixosSystem {
        inherit inputs system;
        hostname = "autohostprobe";
        modules = [ (exampleDir + "/hosts/server/configuration.nix") ];
        userRegistry = {
          "probe@*" = fixturesDir + "/autohost-user";
          "probe@autohostprobe" = exampleDir + "/users/bob";
        };
      }).config.users.groups
    )).success;

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
    lib.hasInfix "pure evaluation" msg
    && lib.hasInfix "path value" msg
    && lib.hasInfix "`alice`" msg
    # the local-path fix has no equivalent across a flake-input boundary
    # (inputs.foo + "/..." can never produce a path value) -- the message
    # must point at the real fix (the OTHER flake exporting the path)
    # instead of leaving that case looking like a dead end
    && lib.hasInfix "ANOTHER flake input" msg;

  # a string entry built by CONCATENATING onto a flake input carries store
  # context (builtins.hasContext) unlike a hand-typed one, and is accepted
  # WITHOUT a warning -- see stringPathEntryWarning's own comment for why
  # that distinction is real, not assumed. `inputs.self.outPath` IS
  # exampleDir (checks/builders/default.nix), so this reaches the exact
  # same `users/alice` directory as the path-literal entries elsewhere in
  # this file.
  context-carrying-string-entry-no-warning =
    builtins.attrNames (
      myLib.buildHomeConfigurations {
        laptop = {
          inherit inputs system;
          userRegistry."alice" = inputs.self + "/users/alice";
          loginHomes = [ "alice" ];
        };
      }
    ) == [ "alice@laptop" ];

  # ── userRegistry auto-discovery (resolveUserRegistry) ──

  # userRegistry OMITTED ENTIRELY + loginFlakeRef defaulting to
  # inputs.self: auto-discovery triggers and the discovered user's
  # configuration.nix is applied.
  auto-discovery-triggers-on-omitted-registry =
    (myLib.mkNixosSystem {
      inputs = autoDiscoverInputs;
      inherit system;
      hostname = "autodiscoverprobe";
      modules = [ (exampleDir + "/hosts/server/configuration.nix") ];
    }).config.users.groups ? auto-discovered-pat;

  # an explicit `userRegistry = { }` -- "wasGiven" true, per
  # resolveUserRegistry's own doc comment -- disables auto-discovery even
  # though the same root has a users/ directory to find
  explicit-empty-registry-disables-auto-discovery =
    !(
      (myLib.mkNixosSystem {
        inputs = autoDiscoverInputs;
        inherit system;
        hostname = "autodiscoverdisabledprobe";
        modules = [ (exampleDir + "/hosts/server/configuration.nix") ];
        userRegistry = { };
      }).config.users.groups ? auto-discovered-pat
    );

  # a STRING loginFlakeRef has no attributes to read a users/ directory
  # off, so auto-discovery never applies to it -- even with userRegistry
  # omitted, the host builds with no discovered users
  string-login-flake-ref-skips-auto-discovery =
    !(
      (myLib.mkNixosSystem {
        inputs = autoDiscoverInputs;
        inherit system;
        hostname = "autodiscoverstringprobe";
        modules = [ (exampleDir + "/hosts/server/configuration.nix") ];
        loginFlakeRef = "/etc/nixos";
      }).config.users.groups ? auto-discovered-pat
    );

  # ... and that STRING loginFlakeRef case also warns (message exported as
  # data, same "warn is not observable, pin the text" treatment as
  # stringPathEntryWarning above)
  string-flake-ref-warning-text =
    let
      registry = import (repoDir + "/lib/nixos/internal/registry.nix") {
        inherit lib;
        self = myLib;
      };
      msg = registry.stringFlakeRefWarning "laptop" "/etc/nixos";
    in
    lib.hasInfix "not a flake input" msg
    && lib.hasInfix "LIVE at login" msg
    && lib.hasInfix "`laptop`" msg
    && lib.hasInfix "auto-discovery" msg;

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
  # See badRegistryKey's own comment (lib/nixos/internal/registry.nix) for
  # why both of these throw: two parsers used to disagree on keys like this.
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
