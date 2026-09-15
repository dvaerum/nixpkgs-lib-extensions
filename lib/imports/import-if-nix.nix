# Per lib/default.nix's `{ lib, self, ... }` calling convention (see there).
{ self, ... }: {
  /**
    Import a path only when it contains valid, importable Nix; otherwise
    return `{ }` (a harmless no-op module) with a warning naming the
    reason. Exactly `importIfNixOr` with the default fixed to `{ }` -- see
    that function for the full semantics; use it directly to provide your
    own fallback value.

    Because the fallback is always the plain attrset `{ }`, this function
    is for module-shaped or plain-attrset content only -- fine for
    `imports = [ (extLib.importIfNix builderPkgs ./private.nix) ]`, where
    the module system applies whatever comes back either way. If `path` is
    expected to be a FUNCTION you call yourself, `{ }` is not callable and
    that call throws on the fallback branch; use `importIfNixOr` instead,
    with a `default` shaped to match.

    # Example

    ```nix
    # CI-safe secrets: locally imported, an encrypted blob on CI becomes
    # { }. `extLib` and `builderPkgs` are both specialArgs this library's
    # builders provide; inside an `imports` list use `builderPkgs`, never
    # the `pkgs` module argument (see the `pkgs` argument below).
    { extLib, builderPkgs, ... }:
    {
      imports = [
        (extLib.importIfNix builderPkgs ./private.nix)
      ];
    }

    # elsewhere -- outside an imports list, any package set will do
    # extLib = inputs.nixpkgs-lib-extensions.lib
    # warns: unsupported extension
    extLib.importIfNix pkgs ./README.md
    => { }
    # warns: does not exist
    extLib.importIfNix pkgs ./missing.nix
    => { }
    # some-dir has a default.nix
    extLib.importIfNix pkgs ./some-dir
    => <the imported value>
    ```

    # Type

    ```
    importIfNix :: pkgs -> Path -> Any | { }
    ```

    # Arguments

    pkgs
    : A package set used to build the validity probe (IFD). In an
    : `imports` list it must not be the `pkgs` module argument; modules
    : reached through this library's builders get `builderPkgs` for
    : exactly that -- see `importIfNixOr`'s `pkgs` argument for the
    : mechanism and for what to pass when you are not using them.

    path
    : The path (or absolute path string) to inspect and maybe import.
  */
  importIfNix = pkgs: path: self.importIfNixOr pkgs path { };
}
