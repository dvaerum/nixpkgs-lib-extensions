# This file is a function-file: the lib loader (lib/default.nix) applies it
# to `extLib` so it can delegate to its sibling `importIfNixOr`.
extLib: {
  /**
    Import a path only when it contains valid, importable Nix; otherwise
    return `{ }` (a harmless no-op module) with a warning naming the
    reason. Exactly `importIfNixOr` with the default fixed to `{ }` -- see
    that function for the full semantics; use it directly to provide your
    own fallback value.

    # Example

    ```nix
    # extLib = inputs.nixpkgs-lib-extensions.lib
    # CI-safe secrets: locally imported, an
    # encrypted blob on CI becomes { }
    imports = [
      (extLib.importIfNix pkgs ./private.nix)
    ];

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
    : A package set used to build the validity probe (IFD).

    path
    : The path (or absolute path string) to inspect and maybe import.
  */
  importIfNix = pkgs: path: extLib.importIfNixOr pkgs path { };
}
