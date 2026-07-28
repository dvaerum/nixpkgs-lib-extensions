{
  /**
    A function from a username to a NixOS module declaring that user as a
    normal account whose primary group is a private group named after the
    user (the Debian/Fedora "user private group" scheme, instead of NixOS's
    shared `users` group) -- so by default a user is only a member of their
    own group.

    This is the default `userModuleFn` of `nixosConfigurationsBuilder`, so
    every user derived from the `homeConfigurations` registry gets a login
    account automatically. Pass your own function when accounts need more,
    or `userModuleFn = null` to disable account creation.

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
        # the default shell, defined once at priority 999 instead of
        # via NixOS's useDefaultShell path -- this makes "root" a valid
        # registry user (root's built-in shell definition would collide
        # with the useDefaultShell one); a plain `shell = ...` wins
        useDefaultShell = false;
        shell = config.users.defaultUserShell;
      };
      users.groups.alice = { };
    }

    # a custom userModuleFn can build on it:
    userModuleFn = username: {
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
    _file = ./normalUserModule.nix;
    imports = [
      (
        { config, lib, ... }:
        {
          users.users.${username} = {
            isNormalUser = true;
            # priority 900: beats isNormalUser's own mkDefault "users" (1000),
            # still loses to a plain `group = ...` assignment (100)
            group = lib.mkOverride 900 username;
            # `isNormalUser` normally triggers NixOS's default-shell path
            # (useDefaultShell -> a mkDefault shell definition). For root
            # that collides with NixOS's built-in mkDefault root.shell:
            # two equal-priority definitions of a unique option. Suppress
            # that path and define the same value once at priority 999 --
            # beats both mkDefaults (1000), loses to a plain `shell = ...`
            # assignment (100).
            useDefaultShell = lib.mkOverride 900 false;
            shell = lib.mkOverride 999 config.users.defaultUserShell;
          };
          users.groups.${username} = { };
        }
      )
    ];
  };
}
