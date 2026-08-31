# Loaded by lib/default.nix under the one calling convention: `self` is the
# fully assembled nixpkgs-lib-extensions lib (a fixed point), `lib` is nixpkgs'.
{ lib, ... }:
{
  /**
    Auto-discover a directory of nixpkgs patches, classified by filename,
    for the builders' `patches` argument (fed to `pkgs.applyPatches` --
    see `mkNixosSystem`'s doc comment). Returns a plain list.

    You will usually NOT call this directly: a `patches` list element
    that is a directory auto-expands through it already (see
    `mkNixosSystem`'s `patches` argument) -- `patches = [ ./patches ];`
    is enough, mixed with explicit `.patch` paths or derivations if
    wanted. Call it yourself only for something the builder's own
    expansion cannot do, e.g. filtering the discovered list before use:
    `patches = builtins.filter keep (discoverPatches pkgs ./patches);`.

    | Filename                                  | Effect |
    | ------------------------------------------ | ------ |
    | `<name>.patch`                             | A local unified-diff patch, used as-is. |
    | `<name>.nix`                               | A REMOTE patch: the file must evaluate to a function `pkgs: <derivation>` -- the common form is `pkgs.fetchpatch { url = ...; hash = ...; }` against an upstream PR's `.diff` URL. Called with `pkgs`, and the resulting derivation is used as the patch. |
    | anything ending in `.disabled`             | Ignored, no warning -- e.g. `<name>.patch.disabled` or `<name>.nix.disabled` keeps a known-good copy around without deleting it or applying it. |
    | `*.md`                                     | Ignored, no warning -- documentation (a README explaining the convention, say). |
    | anything else                              | Ignored, WITH an evaluation warning naming the exact file -- a skipped file is never a silent mystery. |

    A stray subdirectory, or a symlink to one, is treated the same as an
    unrecognized filename: warned and skipped. A symlink to a REGULAR file
    is resolved and classified by what it points at, same rule as
    `importIfNixOr`/`readIfPlainOr` -- so a symlinked `.patch`/`.nix` file
    is picked up like its target. A DANGLING symlink is not specially
    detected (Nix has no cheap, non-crashing way to tell "broken link"
    apart from "links to a regular file" -- see the code comment on
    `resolvedType`): it is treated as regular and only fails once the
    patch is actually used, as a plain Nix error naming the missing path
    rather than a warning naming the symlink.

    Applied in LEXICOGRAPHIC filename order (`builtins.readDir`'s own
    ordering) -- `.patch` and `.nix` entries interleave by name, so prefix
    filenames with `10-`, `50-`, `99-`, etc. when application order
    matters.

    A missing directory is NOT an error: it is treated the same as an
    empty one (`[ ]`) -- a repo with no patches at all should not need to
    create an empty directory just to call this.

    # Example

    ```nix
    # the usual way -- no call needed, the builder expands the directory itself
    patches = [ ./patches ];

    # calling it directly, only needed for something the builder's own
    # expansion cannot do, e.g. filtering:
    # extLib = inputs.nixpkgs-lib-extensions.lib
    patches = builtins.filter (p: builtins.baseNameOf (toString p) != "flaky.patch") (
      extLib.discoverPatches pkgs ./patches
    );
    ```

    ```
    patches/
      10-foundational.patch
      50-feature.nix              # pkgs: pkgs.fetchpatch { url = ...; hash = ...; }
      99-cleanup.patch.disabled   # ignored
      README.md                  # ignored
      notes.txt                  # WARNS: unrecognized filename
    ```

    # Type

    ```
    discoverPatches :: pkgs -> Path -> [ Path | Derivation ]
    ```

    # Arguments

    pkgs
    : The package set passed to each `.nix` remote-patch file (`import file pkgs`).

    dir
    : The directory to scan. Non-existent is treated as empty, not an error.
  */
  discoverPatches =
    pkgs: dir:
    let
      entries = if lib.pathExists dir then builtins.readDir dir else { };

      # Same symlink-resolution rule as importIfNixOr/readIfPlainOr: readDir
      # reports "symlink" without following it, so a link is reclassified
      # by what it resolves to. `toString target + "/."`, NOT
      # `target + "/."`: the latter stays a Nix PATH value, and Nix
      # silently normalizes away a trailing "/." when constructing one, so
      # `pathExists` would see the same path either way and always report
      # "directory". Stringifying first keeps the literal "/.", which only
      # stat's successfully when the (possibly symlinked) target really is
      # a directory.
      #
      # DANGLING symlinks are NOT specially detected here, deliberately:
      # `builtins.pathExists` reports true for a broken symlink too (it
      # does not dereference for existence, only for the "/." directory
      # check), and the one primop that WOULD notice (`readFile`,
      # attempting to actually open the target) throws an error `tryEval`
      # does not catch -- confirmed by testing, not assumed; this same gap
      # already exists in importIfNixOr/readIfPlainOr despite their doc
      # comments claiming "a dangling link counts as missing" (worth a
      # separate fix there). A broken symlink here is classified
      # "regular" and only fails once `applyPatches`/`import` actually
      # tries to use it -- a real, if less friendly, Nix error rather than
      # a silently skipped or silently wrong patch either way.
      resolvedType =
        name: rawType:
        if rawType != "symlink" then
          rawType
        else if builtins.pathExists (toString (dir + "/${name}") + "/.") then
          "directory"
        else
          "regular";

      classify =
        name:
        if resolvedType name entries.${name} != "regular" then
          "skip"
        else if lib.hasSuffix ".disabled" name then
          "disabled"
        else if lib.hasSuffix ".patch" name then
          "local"
        else if lib.hasSuffix ".nix" name then
          "remote"
        else if lib.hasSuffix ".md" name then
          "doc"
        else
          "unknown";

      classified = map (name: {
        inherit name;
        class = classify name;
      }) (builtins.attrNames entries);

      applicable = lib.filter (e: e.class == "local" || e.class == "remote") classified;
      # "skip" (non-regular) and "unknown" (regular but unrecognized
      # suffix) both warn -- named separately only so the message can say
      # WHICH problem it was, not because they are handled differently.
      unrecognized = lib.filter (e: e.class == "unknown" || e.class == "skip") classified;

      patchPath = name: dir + "/${name}";
      toPatch = e: if e.class == "local" then patchPath e.name else import (patchPath e.name) pkgs;

      # Names the exact file AND the directory it was found in -- discovery
      # runs across however many `discoverPatches` call sites a consumer
      # has, so "which file, in which directory" is the whole point of the
      # message; naming just the filename would leave a multi-directory
      # setup guessing which one warned.
      warnMsg = e: ''
        nixpkgs-lib-extensions: discoverPatches ${toString dir}/${e.name}: ${
          if e.class == "skip" then
            "is not a regular file (or a symlink to one)"
          else
            "has an unrecognized filename"
        }, ignoring it. Expected one of:
          <name>.patch              a local unified-diff patch
          <name>.nix                a remote patch (file evaluates to: pkgs: <derivation>)
          <name>.patch.disabled     a disabled local patch (kept around)
          <name>.nix.disabled       a disabled remote patch (kept around)
          *.md                      documentation (e.g. a README)
      '';
    in
    lib.foldl' (acc: e: lib.warn (warnMsg e) acc) (map toPatch applicable) unrecognized;
}
