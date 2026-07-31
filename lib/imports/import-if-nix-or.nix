# Loaded by lib/default.nix under the one calling convention: `self` is the
# fully assembled nixpkgs-lib-extensions lib (a fixed point), `lib` is nixpkgs'.
{ ... }:
{
  /**
    Import a path only when it contains valid, importable Nix; otherwise
    return `default` instead of aborting evaluation. `importIfNix` is the
    same function with the default fixed to `{ }`.

    Made for setups where secret files are encrypted in the remote repo
    (e.g. git-crypt): locally `private.nix` is plain Nix and gets imported;
    on a CI checkout the same path is an encrypted blob, which fails the
    validity probe and becomes the (non-secret) default -- so the same
    configuration evaluates in both places.

    Accepted: a regular file with the `.nix` suffix whose content parses as
    Nix, or a directory whose `default.nix` does. Everything else yields
    `default` WITH an evaluation warning naming the reason (missing path,
    unsupported file extension, directory without default.nix, or content
    that is not valid Nix) -- a skipped import is never a silent mystery.
    When scanning directories, filter names by the `.nix` suffix first so
    intentionally skipped files do not warn.

    Content validity cannot be checked in pure evaluation (a parse error
    from `import` is uncatchable, and `builtins.readFile` refuses binary
    files), so the probe runs `nix-instantiate --parse` in a small
    derivation -- import-from-derivation, built during evaluation on the
    machine doing the evaluating, and cached per file content.

    # Example

    ```nix
    # extLib = inputs.nixpkgs-lib-extensions.lib
    # CI-safe secrets with non-secret placeholders:
    extLib.importIfNixOr pkgs ./private.nix {
      tester = 1212;
    }
    # locally  => <the imported value>
    # on CI    => { tester = 1212; } (warns)
    ```

    # Type

    ```
    importIfNixOr :: pkgs -> Path -> Any -> Any
    ```

    # Arguments

    pkgs
    : A package set used to build the validity probe (IFD).

    path
    : The path (or absolute path string) to inspect and maybe import.

    default
    : The value returned (with a warning) when `path` is not importable.
  */
  importIfNixOr =
    pkgs: path: default:
    let
      type = if builtins.pathExists path then builtins.readFileType path else null;

      # every skipped import says WHY -- a silently skipped file should
      # never be a silent mystery
      skip =
        reason:
        builtins.warn "importIfNixOr: ${toString path} ${reason}; using the default instead" default;

      # "does this file parse as Nix?" -- answered by a tiny derivation,
      # since pure evaluation cannot inspect arbitrary file contents
      parses =
        file:
        builtins.readFile (
          pkgs.runCommand "is-valid-nix" { } ''
            # give nix-instantiate writable state so it can start up
            # inside the build sandbox; only the parser is used
            export HOME=$TMPDIR
            export NIX_STORE_DIR=$TMPDIR/nix/store
            export NIX_STATE_DIR=$TMPDIR/nix/state
            export NIX_CONF_DIR=$TMPDIR/nix/conf
            if ${pkgs.nix}/bin/nix-instantiate --parse ${file} > /dev/null 2>&1; then
              printf ok > $out
            else
              printf invalid > $out
            fi
          ''
        ) == "ok";
    in
    if type == null then
      skip "does not exist"
    else if type == "regular" then
      (
        if builtins.match ".*\\.nix" (toString path) == null then
          skip "has an unsupported file extension (expected .nix)"
        else if parses path then
          import path
        else
          skip "is not valid Nix (still encrypted?)"
      )
    else if type == "directory" then
      (
        if !builtins.pathExists (path + "/default.nix") then
          skip "is a directory without a default.nix"
        else if parses (path + "/default.nix") then
          import path
        else
          skip "has a default.nix that is not valid Nix (still encrypted?)"
      )
    else
      skip "is not a regular file or directory";
}
