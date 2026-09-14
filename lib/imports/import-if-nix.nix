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
    # CI-safe secrets: locally imported, an
    # encrypted blob on CI becomes { }. In a module reached through this
    # library's builders, `extLib` and `builderPkgs` are both specialArgs
    # they provide -- and inside an `imports` list it MUST be
    # `builderPkgs`, never the `pkgs` module argument (see importIfNixOr's
    # `pkgs` argument for why: the probe is IFD, and forcing the module
    # argument recurses through the fixed point being assembled).
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
    : `imports` list this must be `builderPkgs`, not the `pkgs` module
    : argument -- see `importIfNixOr`'s `pkgs` argument for the mechanism.

    path
    : The path (or absolute path string) to inspect and maybe import.
  */
  importIfNix = pkgs: path: self.importIfNixOr pkgs path { };
}
