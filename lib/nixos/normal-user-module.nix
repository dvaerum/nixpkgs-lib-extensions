# Per lib/default.nix's `{ lib, self, ... }` calling convention (see there).
{ ... }:
{
  /**
    A function from a username and its resolved account kind to a NixOS
    module declaring that user as either a normal account -- private
    primary group named after the user (the Debian/Fedora "user private
    group" scheme, instead of NixOS's shared `users` group), so by default
    a user is only a member of their own group -- or a system account
    (`isSystemUser = true;`, nothing else: uid, group, and home are the
    account's own `configuration.nix` to declare, exactly like `root`).

    This is the default `userModule` of `mkNixosSystem`, which resolves
    `isNormalUser` itself (from the tree user's `_defaults.nix`, see
    "Making a users-tree entry a system account" below) and pre-binds it
    before calling this function -- see mk-system.nix's own
    `perUserModules`. So every user derived from the users tree gets an
    account automatically. Pass your own function when accounts need
    more, or `userModule = null` to disable account creation.

    # Example

    ```nix
    # extLib = inputs.nixpkgs-lib-extensions.lib
    extLib.normalUserModule "alice" true
    =>
    # a module equivalent to:
    {
      users.users.alice = {
        isNormalUser = true;
        group = "alice"; # overridable with a plain assignment
      };
      users.groups.alice = { };
    }

    extLib.normalUserModule "svc" false
    =>
    # a module equivalent to:
    {
      users.users.svc.isSystemUser = true;
    }
    # -- uid, group, home, and shell are still svc's OWN
    # configuration.nix to declare (see "Making a users-tree entry a
    # system account" below); mk-system.nix always resolves `root` to a
    # system account regardless of `_defaults.nix`, so `root` is a valid
    # users-tree entry too -- it only ever gets its home.nix /
    # configuration.nix, never THIS module's isSystemUser (NixOS's own
    # core module already fully owns root's account).

    # a custom userModule can build on it -- mkNixosSystem passes the
    # pre-bound, unary form (see above), so a wrapper written against
    # `userModule` itself never sees the second argument:
    userModule = username: {
      imports = [ (extLib.normalUserModule username true) ];
      users.users.${username}.extraGroups = [ "networkmanager" ];
    };
    ```

    # Making a users-tree entry a system account

    A tree user that's really a service account (still needs its own
    `configuration.nix`/`home.nix`, but shouldn't get a normal login)
    becomes a system account by declaring `isSystemUser = true;` in
    `users/<name>/_defaults.nix`:

    ```nix
    # users/<name>/_defaults.nix
    { isSystemUser = true; }
    ```

    This module then sets `isSystemUser = true;` itself -- `_defaults.nix`
    alone is enough, `configuration.nix` does NOT need to repeat it -- but
    still leaves `uid`/`group`/`home`/`shell` entirely to `configuration.nix`,
    same as any system account:

    ```nix
    # users/<name>/configuration.nix
    {
      users.users.<name> = {
        uid = 411;
        group = "<name>";
        home = "/var/lib/<name>";
        createHome = true;
      };
      users.groups.<name> = { };
    }
    ```

    Picking the uid: 0-399 is fully claimed by nixpkgs' own static
    `ids.nix` (400+ services); 400-999 is what NixOS's *dynamic*
    system-user allocator owns (`isSystemUser = true` with `uid`
    left `null` picks one from here on activation, RFC 0052), handed
    out from 999 **downward**. A manually pinned uid in that same
    range never collides with it -- the allocator always checks
    `/etc/passwd` first and skips anything already taken -- but
    picking low (400-450) keeps it as far as possible from the end
    the allocator actually reaches on any real host.

    A `configuration.nix` that ALSO sets `isSystemUser`/`isNormalUser`
    directly (redundant, but not forbidden) MUST agree with what
    `_defaults.nix` resolved -- the assertions below catch either
    mismatch (each direction: a resolved-normal user whose
    `configuration.nix` sets `isSystemUser = true;`, or a resolved-system
    user whose `configuration.nix` sets `isNormalUser = true;`) with a
    message naming the actual fix, rather than NixOS's own generic
    "exactly one of `isSystemUser` and `isNormalUser` must be set".

    # Type

    ```
    normalUserModule :: String -> Bool -> Module
    ```

    # Arguments

    username
    : The name of the user account (and its private group) to create.

    isNormalUser
    : Whether `username` resolves to a normal account (`true`) or a
    : system account (`false`) -- see "Making a users-tree entry a
    : system account" above. `mkNixosSystem` resolves this itself from
    : the tree user's `_defaults.nix` before calling this function; a
    : direct caller decides it however it needs to.
  */
  normalUserModule = username: isNormalUser: {
    _file = ./normal-user-module.nix;
    imports = [
      (
        { config, lib, ... }:
        {
          users.users.${username} = {
            isNormalUser = lib.mkIf isNormalUser true;
            # priority 900: beats isNormalUser's own mkDefault "users" (1000),
            # still loses to a plain `group = ...` assignment (100)
            group = lib.mkIf isNormalUser (lib.mkOverride 900 username);
            isSystemUser = lib.mkIf (!isNormalUser) true;
          };
          users.groups = lib.mkIf isNormalUser { ${username} = { }; };

          # Without these, a `configuration.nix` disagreeing with the
          # `_defaults.nix`-resolved kind fails with NixOS's own "exactly
          # one of isSystemUser and isNormalUser must be set" -- true,
          # but it never mentions that something else already set the
          # other one, let alone what to do about it. Reads `config` only
          # inside an ASSERTION, not a definition, so it cannot feed back
          # into the users wiring above -- the same safe pattern this
          # module always used, even before `isNormalUser` moved to a
          # builder-resolved argument.
          assertions = [
            {
              assertion = !(isNormalUser && config.users.users.${username}.isSystemUser);
              message = ''
                nixpkgs-lib-extensions: user `${username}` is declared `isSystemUser = true` in `configuration.nix`, but resolved as a NORMAL account (no `isSystemUser = true;` in `users/${username}/_defaults.nix`), and NixOS allows only one of the two.
                Fix it by one of:
                  - adding `isSystemUser = true;` to `users/${username}/_defaults.nix`, so this module resolves it as a system account instead;
                  - removing `users/${username}/` from the users tree, if the account is not a person;
                  - passing `userModule = null` and creating the accounts yourself.
              '';
            }
            {
              assertion = !(!isNormalUser && config.users.users.${username}.isNormalUser);
              message = ''
                nixpkgs-lib-extensions: user `${username}` is declared `isNormalUser = true` in `configuration.nix`, but resolved as a SYSTEM account (`isSystemUser = true;` in `users/${username}/_defaults.nix`), and NixOS allows only one of the two.
                Fix it by one of:
                  - removing `isSystemUser = true;` from `users/${username}/_defaults.nix`, so this module resolves it as a normal account instead;
                  - removing the redundant `isNormalUser = true;` from `configuration.nix` -- `_defaults.nix` alone is enough.
              '';
            }
          ];
        }
      )
    ];
  };
}
