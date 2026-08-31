# Eval-time tests for lib.imports.discoverPatches, run by `nix flake check`.
#
# Fixtures are COMMITTED directories under checks/fixtures/ (not built at
# eval time): discoverPatches needs a real, already-existing directory to
# `readDir`, and this is the same shape a consumer's own `./patches`
# directory has. Assertions read only what is safe to force: `toString` on
# a Path never resolves/reads it (even a dangling symlink), and
# `builtins.length` only forces a list's spine, not its elements -- both
# used deliberately to test the "dangling symlink" case (see
# discover-patches-dangling-nix below) without triggering the uncatchable
# crash that forcing its VALUE would cause (documented in discoverPatches'
# own `resolvedType` comment).
{ pkgs, myLib }:
let
  lib = pkgs.lib;

  fixtureDir = ./fixtures/discover-patches;
  result = myLib.discoverPatches pkgs fixtureDir;
  resultStrings = map toString result;

  fixturePath = name: toString (fixtureDir + "/${name}");

  danglingNixDir = ./fixtures/discover-patches-dangling-nix;
in
(import ./run-assertions.nix { inherit pkgs; }).run "discover-patches-tests" {
  # local .patch: included as the plain path, unmodified
  local-patch-included = lib.elem (fixturePath "10-local.patch") resultStrings;

  # remote .nix: imported and called with pkgs, the result (NOT the file
  # path) is what ends up in the list
  remote-nix-resolved-to-derivation = lib.any (
    v: builtins.isAttrs v && (v.pname or v.name or "") == "hello"
  ) result;

  # .patch.disabled / .nix.disabled: excluded, and no path/derivation of
  # theirs leaks into the result under any name
  disabled-local-excluded = !(lib.elem (fixturePath "30-old.patch.disabled") resultStrings);
  disabled-remote-excluded = !(builtins.elem "old" (map (v: v.pname or v.name or "") result));

  # *.md: excluded, no warning (nothing to assert on the warning side --
  # the point is just that it does not appear)
  doc-file-excluded = !(lib.elem (fixturePath "README.md") resultStrings);

  # unrecognized filename: excluded (warns -- see discoverPatches' warnMsg
  # for the message text, not independently re-tested here)
  unknown-file-excluded = !(lib.elem (fixturePath "unknown-file.txt") resultStrings);

  # a real subdirectory: excluded (warns, same as an unrecognized file)
  subdirectory-excluded = !(lib.elem (fixturePath "subdir") resultStrings);

  # a symlink to a directory: excluded (warns) -- distinct from the plain
  # subdirectory case above, exercises the resolvedType symlink branch
  symlink-to-directory-excluded = !(lib.elem (fixturePath "link-to-subdir") resultStrings);

  # a symlink to a REGULAR file: resolved and classified by its target,
  # so it is included -- as ITS OWN path (readDir/toPatch never follow the
  # link to substitute the target's path), not the target's path
  symlink-to-regular-included = lib.elem (fixturePath "50-linked.patch") resultStrings;
  symlink-path-not-substituted-for-target =
    !(
      # the target (10-local.patch) is ALSO independently a real entry and
      # is expected in the list once; this pins that the symlink did not
      # cause it to appear a SECOND time under its own path
      lib.count (s: s == fixturePath "10-local.patch") resultStrings > 1
    );

  # a dangling symlink (points nowhere): NOT specially detected (see the
  # doc comment on resolvedType for why) -- included as a plain path, safe
  # to test via `toString` since that never resolves/reads it
  dangling-local-symlink-included-not-crashed = lib.elem (fixturePath "dangling.patch") resultStrings;

  # exactly the 4 applicable entries: 10-local, 20-remote, 50-linked,
  # dangling -- everything else (disabled x2, README, unknown-file,
  # subdir, link-to-subdir) is excluded
  exactly-the-applicable-entries-included = builtins.length result == 4;

  # a dangling REMOTE (.nix) symlink: also not specially detected, so it
  # is COUNTED (proving it was not silently skipped) without ever being
  # FORCED -- forcing it would `import` a nonexistent path and crash
  # uncatchably, which `builtins.length` (spine-only) avoids by
  # construction.
  dangling-remote-symlink-counted-without-forcing =
    builtins.length (myLib.discoverPatches pkgs danglingNixDir) == 1;

  # a directory that does not exist at all: treated as empty, not an error
  missing-directory-returns-empty-list =
    myLib.discoverPatches pkgs ./fixtures/does-not-exist-discover-patches == [ ];

  # lexicographic ordering (readDir's own, confirmed against the real
  # fixture rather than assumed): digits sort before lowercase letters in
  # ASCII, so the numeric prefixes put 10-/20-/50- ahead of "dangling" --
  # 10-local.patch, 20-remote.nix (-> hello), 50-linked.patch,
  # dangling.patch. Pinned by POSITION, not just membership, so a change
  # that preserves membership but breaks ordering still fails.
  lexicographic-order-preserved =
    (builtins.elemAt resultStrings 0) == fixturePath "10-local.patch"
    && (builtins.isAttrs (builtins.elemAt result 1))
    && (builtins.elemAt resultStrings 2) == fixturePath "50-linked.patch"
    && (builtins.elemAt resultStrings 3) == fixturePath "dangling.patch";
}
