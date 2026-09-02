# Per lib/default.nix's `{ lib, self, ... }` calling convention (see there).
{ ... }:
{
  /**
    A function from a username to a NixOS module declaring that user as a
    normal account whose primary group is a private group named after the
    user (the Debian/Fedora "user private group" scheme, instead of NixOS's
    shared `users` group) -- so by default a user is only a member of their
    own group.

    This is the default `userModule` of `mkNixosSystem`, so
    every user derived from the users tree gets a login
    account automatically. Pass your own function when accounts need more,
    or `userModule = null` to disable account creation.

    # Example

    ```nix
    # extLib = inputs.nixpkgs-lib-extensions.lib
    extLib.normalUserModule "alice"
    =>
    # a module equivalent to:
    {
      users.users.alice = {
        isNormalUser = true;
        group = "alice"; # overridable with a plain assignment
      };
      users.groups.alice = { };
    }
    # System accounts are left untouched: when the user's merged uid is
    # below 1000 (root, or a configuration.nix pinning a reserved uid)
    # the module contributes nothing -- NixOS forbids isNormalUser on
    # such accounts, and they define their own group and shell. So
    # "root" is a valid registry entry: it only gets its home.nix /
    # configuration.nix, never account changes.

    # a custom userModule can build on it:
    userModule = username: {
      imports = [ (extLib.normalUserModule username) ];
      users.users.${username}.extraGroups = [ "networkmanager" ];
    };
    ```

    # Type

    ```
    normalUserModule :: String -> Module
    ```

    # Arguments

    username
    : The name of the user account (and its private group) to create.
  */
  normalUserModule = username: {
    _file = ./normal-user-module.nix;
    imports = [
      (
        { config, lib, ... }:
        let
          # An account with a fixed uid below 1000 is a system account --
          # root (uid 0), or any registry user whose configuration.nix pins
          # a reserved uid. NixOS asserts isNormalUser is never combined
          # with such a uid, and those accounts define their own group and
          # shell, so this module leaves them entirely untouched. Reading
          # the merged uid here is safe: this module never defines it.
          #
          # `isSystemUser` deliberately does NOT gate these definitions.
          # It would be the more accurate test -- service accounts usually
          # leave uid null -- but `users.groups` and the user submodule are
          # mutually dependent in NixOS, so deciding what to DEFINE by
          # reading it is an infinite recursion. The conflict is caught by
          # the assertion below instead, which reads config at assertion
          # time and so does not feed back into the users wiring.
          normalAccount =
            let
              uid = config.users.users.${username}.uid;
            in
            uid == null || uid >= 1000;
        in
        {
          users.users.${username} = {
            isNormalUser = lib.mkIf normalAccount true;
            # priority 900: beats isNormalUser's own mkDefault "users" (1000),
            # still loses to a plain `group = ...` assignment (100)
            group = lib.mkIf normalAccount (lib.mkOverride 900 username);
          };
          users.groups = lib.mkIf normalAccount { ${username} = { }; };

          # Without this, declaring `isSystemUser = true` for a registry
          # user fails with NixOS's own "exactly one of isSystemUser and
          # isNormalUser must be set" -- true, but it never mentions that
          # something else set isNormalUser, let alone what to do about it.
          assertions = [
            {
              assertion = !(normalAccount && config.users.users.${username}.isSystemUser);
              message = ''
                nixpkgs-lib-extensions: user `${username}` is declared `isSystemUser = true`, but this host's `userModule` (by default `normalUserModule`) also makes every user from the users tree a NORMAL account, and NixOS allows only one of the two.
                Fix it by one of:
                  - removing `users/${username}/` from the users tree, if the account is not a person;
                  - pinning a uid below 1000 for `${username}`, which this module leaves alone;
                  - passing `userModule = null` and creating the accounts yourself.
              '';
            }
          ];
        }
      )
    ];
  };
}
