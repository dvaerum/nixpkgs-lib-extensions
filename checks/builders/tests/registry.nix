# The users tree: how a user's directory (and its `hosts/<host>`
# override) resolves to a user on a host, and which homes that produces.
{
  lib,
  myLib,
  inputs,
  system,
  example,
  laptop,
  server,
  exampleUsers,
  exampleDir,
  fixturesDir,
  invalidFixturesDir,
  repoDir,
  ...
}:
{
  # exampleUsers is the ctx-shared canonical list (ext-options.nix
  # compares option values against the same one)
  users-derived-from-tree = laptop.config.nixpkgsLibExtensions.users == exampleUsers;

  # companion configuration.nix files from user directories reach the system
  companion-config-applied = laptop.config.users.groups ? media;
  system-only-user-config-applied = laptop.config.users.groups ? backup-operators;

  # a user's own configuration.nix applies on every host ...
  base-config-applied = laptop.config.users.groups ? vpn;
  # ... and their hosts/<hostname>/configuration.nix MERGES on top there
  host-override-merges = laptop.config.users.groups ? scanner;

  # ── the two output shapes ──
  # a user with a home.nix of their own gets a HOST-LESS home: one
  # `homeConfigurations."<user>"` usable on any machine
  hostless-home-for-plain-user = example.homeConfigurations ? "alice";
  # a user with a hosts/<h>/ override ALSO gets the per-host key ...
  per-host-home-key = example.homeConfigurations ? "frank@laptop";
  # ... and keeps the host-less one: adding a machine-specific override
  # must not remove the ability to build that user anywhere else
  per-host-does-not-remove-hostless = example.homeConfigurations ? "frank";
  # a user with ONLY hosts/<h>/ files exists on that host and nowhere
  # else -- no host-less key at all
  hosts-only-user-has-no-hostless-key =
    example.homeConfigurations ? "bob@laptop" && !(example.homeConfigurations ? "bob");
  # a user whose only host is not declared in this flake produces nothing
  undeclared-host-user-absent =
    !(example.homeConfigurations ? "carol") && !(example.homeConfigurations ? "carol@otherhost");
  # a directory with only configuration.nix is a system-only user: an
  # account, but no home output of any shape
  system-only-user-has-no-home =
    !(example.homeConfigurations ? "eve") && !(example.homeConfigurations ? "eve@laptop");

  # the host-less home must NOT pick up any hosts/<h> override, and the
  # per-host one must merge BOTH (proven by group names its
  # configuration.nix creates, read off the system that imports them)
  hostless-home-excludes-host-override =
    let
      resolved = import (repoDir + "/lib/nixos/internal/registry.nix") {
        inherit lib;
        self = myLib;
      };
      tree = {
        frank = exampleDir + "/users/frank";
      };
    in
    lib.length (resolved.entryDirsFor tree null "frank") == 1
    && lib.length (resolved.entryDirsFor tree "laptop" "frank") == 2;

  # discoverHostsForUser: the hostnames a user directory has overrides for
  discover-hosts-for-user =
    let
      resolved = import (repoDir + "/lib/nixos/internal/registry.nix") {
        inherit lib;
        self = myLib;
      };
    in
    resolved.discoverHostsForUser (exampleDir + "/users/frank") == [ "laptop" ]
    && resolved.discoverHostsForUser (exampleDir + "/users/alice") == [ ];

  # ── entry validation ──
  # a users-tree directory that is neither a user nor a hosts/ container
  # is skipped by discovery with a warning, not silently accepted
  malformed-user-directory-skipped =
    !(
      (myLib.buildHomeConfigurations {
        inherit inputs system;
        rootPath = invalidFixturesDir;
        traceDiscoveredUsers = false;
      }) ? "no-nix-files"
    );

  # ── per-host `users` selection ──
  # the server selects none of the tree's users
  server-no-users = server.config.nixpkgsLibExtensions.users == [ ];
  # ... and a named subset takes exactly those
  users-selection-takes-subset =
    (myLib.mkNixosSystem {
      inherit inputs system;
      hostname = "subsethost";
      modules = [ (exampleDir + "/hosts/server/configuration.nix") ];
      users = [ "alice" ];
    }).config.nixpkgsLibExtensions.users == [ "alice" ];
  # ... and a name that is not in the tree is a typo, not silence
  users-selection-typo-throws =
    !(builtins.tryEval (
      (myLib.mkNixosSystem {
        inherit inputs system;
        hostname = "typohost";
        modules = [ (exampleDir + "/hosts/server/configuration.nix") ];
        users = [ "alicce" ];
      }).config.nixpkgsLibExtensions.users
    )).success;
}
