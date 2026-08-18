# Loaded by lib/default.nix under the one calling convention: `self` is the
# fully assembled nixpkgs-lib-extensions lib (a fixed point), `lib` is nixpkgs'.
{ lib, ... }:
{
  /**
    Import a path only when it contains valid, importable Nix; otherwise
    return `default` instead of aborting evaluation. `importIfNix` is the
    same function with the default fixed to `{ }`.

    The import is BARE -- `import path`, nothing applied. Dropped into a
    NixOS/home-manager module's `imports` list, that is exactly what you
    want: if `path`'s content is a module FUNCTION
    (`{ config, pkgs, lib, ... }: { ... }`), the module system applies it
    itself and already supplies `config`/`pkgs`/`lib` plus any specialArgs
    the builders wire in (`inputs`, `extLib`, `rootPath`, ...) -- no extra
    plumbing needed here. Calling the RESULT yourself instead (outside a
    module context) needs `default` to match the shape `path` is expected
    to have -- see `default` below.

    Made for setups where secret files are encrypted in the remote repo
    (e.g. via git-crypt, which encrypts individual files in a git repo
    transparently -- a checkout without the decryption key sees raw
    ciphertext instead of the file's real content): locally `private.nix`
    is plain Nix and gets imported;
    on a CI checkout the same path is an encrypted blob, which fails the
    validity probe and becomes the (non-secret) default -- so the same
    configuration evaluates in both places.

    Accepted: a regular file with the `.nix` suffix whose content parses as
    Nix, or a directory whose `default.nix` does. Symlinks are followed
    and classified by what they resolve to (a link to a valid `.nix` file
    imports like its target; a dangling link counts as missing).
    Everything else yields
    `default` WITH an evaluation warning naming the reason (missing path,
    unsupported file extension, directory without default.nix, or content
    that is not valid Nix) -- a skipped import is never a silent mystery.
    When scanning directories, filter names by the `.nix` suffix first so
    intentionally skipped files do not warn.

    Content validity cannot be checked in pure evaluation (a parse error
    from `import` is uncatchable, and `builtins.readFile` refuses binary
    files), so the probe runs `nix-instantiate --parse` in a small
    derivation -- import-from-derivation, built during evaluation on the
    machine doing the evaluating (`preferLocalBuild`, no substitution),
    and cached per file content. IFD is REQUIRED: any evaluation using
    `importIfNix`/`importIfNixOr` fails under
    `--no-allow-import-from-derivation` (the builders' `patches`
    argument shares this constraint).

    Only an actual parse REJECTION counts as invalid content: when
    nix-instantiate fails for any other reason (a crash, a killed
    process), the function THROWS instead of quietly returning `default`
    -- that is a broken probe, not an encrypted file. If the probe
    derivation itself fails to build, evaluation aborts with that build
    error (IFD cannot continue past it). And the verdict comes from the
    `pkgs.nix` parser rather than the evaluating Nix, so a parser-version
    skew between the two can (rarely) let a file pass the probe and still
    fail the actual `import`, or reject what the evaluator would accept.

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
    : If you plan to CALL the resolved value yourself (rather than let a
    : module system apply it), give `default` the SAME shape as what a
    : valid `path` would produce -- e.g. a function of the same arity --
    : so applying arguments works the same way whether the valid or the
    : fallback branch fired. Mismatched shapes only fail on the fallback
    : path, so this can look fine locally and break only on CI, where the
    : encrypted file actually takes that branch.
  */
  importIfNixOr =
    pkgs: path: default:
    let
      type = if lib.pathExists path then builtins.readFileType path else null;

      # A symlink is classified by what it RESOLVES to. readFileType alone
      # reports "symlink" without following, and Nix has no readlink -- but
      # pathExists DOES follow, and stat'ing the path with a literal
      # trailing "/." (as a string, so the "." is not normalized away)
      # succeeds exactly when the link resolves to a directory. A dangling
      # link never gets here: the pathExists guard above already classified
      # it as missing.
      resolvedType =
        if type != "symlink" then
          type
        else if builtins.pathExists (toString path + "/.") then
          "directory"
        else
          "regular";

      # every skipped import says WHY -- a silently skipped file should
      # never be a silent mystery
      skip =
        reason: lib.warn "importIfNixOr: ${toString path} ${reason}; using the default instead" default;

      # The probed file reaches the probe as a FLAT store copy
      # (builtins.path, recursive = false), which follows a
      # final-component symlink -- plain `${file}` interpolation would
      # copy the symlink itself, dangling inside the build sandbox. For a
      # regular file the flat copy is content-addressed the same way, so
      # the per-content probe caching is unchanged.
      probeSrc =
        file:
        builtins.path {
          path = file;
          recursive = false;
          name = "import-if-nix-probe.nix";
        };

      # "does this file parse as Nix?" -- answered by a tiny derivation,
      # since pure evaluation cannot inspect arbitrary file contents.
      # preferLocalBuild/allowSubstitutes: evaluation BLOCKS on this
      # build, so shipping a seconds-long parse probe to a remote builder
      # or asking a substituter for it costs more than running it here --
      # and its output is per-machine throwaway, never worth caching
      # remotely.
      #
      # THREE verdicts, not a boolean: only nix-instantiate actually
      # REJECTING the content (exit 1) is "invalid" -- the one verdict
      # that may mean "still encrypted". Any other failure (a crash, a
      # kill) is "error": the probe broke, and treating that as an
      # invalid file would silently hand out the default on flaky
      # tooling.
      parseVerdict =
        file:
        lib.readFile (
          pkgs.runCommand "is-valid-nix"
            {
              preferLocalBuild = true;
              allowSubstitutes = false;
            }
            ''
              # give nix-instantiate writable state so it can start up
              # inside the build sandbox; only the parser is used
              export HOME=$TMPDIR
              export NIX_STORE_DIR=$TMPDIR/nix/store
              export NIX_STATE_DIR=$TMPDIR/nix/state
              export NIX_CONF_DIR=$TMPDIR/nix/conf
              status=0
              ${pkgs.nix}/bin/nix-instantiate --parse ${probeSrc file} > /dev/null 2>&1 || status=$?
              if [ "$status" -eq 0 ]; then
                printf ok > $out
              elif [ "$status" -eq 1 ]; then
                printf invalid > $out
              else
                printf error > $out
              fi
            ''
        );

      # import on "ok", skip with `reason` on "invalid", THROW on anything
      # else -- see parseVerdict.
      importIfParses =
        file: reason:
        let
          verdict = parseVerdict file;
        in
        if verdict == "ok" then
          import path
        else if verdict == "invalid" then
          skip reason
        else
          throw "importIfNixOr: the validity probe for ${toString path} produced no parse verdict (marker: `${verdict}`): nix-instantiate failed for some reason other than rejecting the content. This is a broken probe, not an encrypted file -- inspect the probe derivation's build log instead of relying on the default value.";
    in
    if type == null then
      skip "does not exist"
    else if resolvedType == "regular" then
      (
        if builtins.match ".*\\.nix" (toString path) == null then
          skip "has an unsupported file extension (expected .nix)"
        else
          importIfParses path "is not valid Nix (still encrypted?)"
      )
    else if resolvedType == "directory" then
      (
        if !lib.pathExists (path + "/default.nix") then
          skip "is a directory without a default.nix"
        else
          importIfParses (path + "/default.nix") "has a default.nix that is not valid Nix (still encrypted?)"
      )
    else
      skip "is not a regular file or directory";
}
