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
        { lib, ... }:
        {
          users.users.${username} = {
            isNormalUser = true;
            # priority 900: beats isNormalUser's own mkDefault "users" (1000),
            # still loses to a plain `group = ...` assignment (100)
            group = lib.mkOverride 900 username;
          };
          users.groups.${username} = { };
        }
      )
    ];
  };
}
