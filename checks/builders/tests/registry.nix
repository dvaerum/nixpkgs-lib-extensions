# The userRegistry registry: user derivation from keys, the
# "<user>@<host>" / "<user>@*" / "<user>" resolution rules, companion
# configuration.nix handling and entry validation.
{
  myLib,
  inputs,
  system,
  example,
  laptop,
  server,
  homesThrow,
  exampleDir,
  invalidFixturesDir,
  ...
}:
{
  users-derived-from-registry =
    laptop._module.specialArgs.listOfUsernames == [
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
  # like something is broken.
  shadowed-plain-entry-ignored =
    !(
      (myLib.nixosConfigurationsBuilder {
        inherit inputs system;
        hostname = "shadowprobe";
        modules = [ (exampleDir + "/hosts/server/configuration.nix") ];
        userRegistry = {
          "grace@*" = exampleDir + "/users/grace-base";
          "grace" = exampleDir + "/users/grace-plain";
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
  # absolute string paths work like path literals
  string-path-entry-works =
    builtins.attrNames (
      myLib.buildHomeConfigurations {
        laptop = {
          inherit inputs system;
          userRegistry."alice" = "${exampleDir + "/users/alice"}";
          loginUsers = [ "alice" ];
        };
      }
    ) == [ "alice@laptop" ];

  # only loginUsers get homeConfigurations outputs: dave/frank/grace are
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
          loginUsers = [
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
  server-no-users = server._module.specialArgs.listOfUsernames == [ ];

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
          loginUsers = [ "helen" ];
        };
      }
    ) == [ "helen@laptop" ];

  # an explicit null registry behaves like an empty one
  null-registry-disables =
    let
      sys = (
        myLib.nixosConfigurationsBuilder {
          inherit inputs system;
          hostname = "nullreg";
          modules = [ (exampleDir + "/hosts/server/configuration.nix") ];
          userRegistry = null;
        }
      );
    in
    sys._module.specialArgs.listOfUsernames == [ ]
    && !(sys.config.systemd.user.services ? home-manager-bootstrap);
}
