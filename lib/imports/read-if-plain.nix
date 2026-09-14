# Per lib/default.nix's `{ lib, self, ... }` calling convention (see there).
{ self, ... }:
{
  /**
    Read a path as plain text only when it is not still git-crypt
    ciphertext; otherwise return `""` with a warning naming the reason.
    Exactly `readIfPlainOr` with the default fixed to `""` -- see that
    function for the full semantics; use it directly to provide your own
    fallback value (e.g. when an empty string is itself a meaningful,
    ambiguous result).

    # Example

    ```nix
    # extLib = inputs.nixpkgs-lib-extensions.lib
    # CI-safe secrets: locally read, an
    # encrypted blob on CI becomes ""
    services.foo.apiToken = extLib.readIfPlain pkgs ./token.txt;
    ```

    # Type

    ```
    readIfPlain :: pkgs -> Path -> String
    ```

    # Arguments

    pkgs
    : A package set used to build the header-check probe (IFD). The
    : ordinary `pkgs` module argument is fine: this returns a string, so
    : its callers are option values in a module body, never `imports`
    : entries -- see `importIfNixOr`'s `pkgs` argument for that case.

    path
    : The path (or absolute path string) to inspect and maybe read.
  */
  readIfPlain = pkgs: path: self.readIfPlainOr pkgs path "";
}
