# Eval-time tests for lib.nixos.discoverUserRegistry, run by `nix flake check`.
#
# Fixtures are a COMMITTED directory under checks/fixtures/ (not built at
# eval time), same rationale as checks/discover-patches.nix: this needs a
# real, already-existing directory to `readDir`, the same shape a
# consumer's own `users/` directory has.
{ pkgs, myLib }:
let
  lib = pkgs.lib;

  fixtureDir = ./fixtures/discover-user-registry;
  result = myLib.discoverUserRegistry fixtureDir;

  entryPath = name: toString (fixtureDir + "/${name}");
in
(import ./run-assertions.nix { inherit pkgs; }).run "discover-user-registry-tests" {
  # a subdirectory with configuration.nix (no home.nix) becomes an
  # entry pointing at the directory itself
  configuration-only-user-included = toString (result.dennis or null) == entryPath "dennis";

  # ... and the same for home.nix (no configuration.nix)
  home-only-user-included = toString (result.root or null) == entryPath "root";

  # a directory with NEITHER file is not a registry entry (warns -- see
  # discoverUserRegistry's own warnMsg for the text, not independently
  # re-tested here, same precedent as discoverPatches' unknown-file case)
  malformed-directory-excluded = !(result ? malformed);

  # a dotfile/dot-directory is ignored, no warning
  dotdir-excluded = !(result ? ".hidden");

  # a plain file is ignored, no warning
  plain-file-excluded = !(result ? "README");

  # a symlink to a user directory is resolved and classified by its
  # target, included as ITS OWN path (not the target's), same rule as
  # discoverPatches' symlink handling
  symlink-to-user-included = toString (result.link-to-dennis or null) == entryPath "link-to-dennis";

  # a symlink to a malformed directory is excluded the same as the
  # malformed directory itself
  symlink-to-malformed-excluded = !(result ? link-to-malformed);

  # exactly the 3 applicable entries: dennis, root, link-to-dennis --
  # everything else (malformed, .hidden, README.md, link-to-malformed) is
  # excluded
  exactly-the-applicable-entries-included = builtins.length (builtins.attrNames result) == 3;

  # a directory that does not exist at all: treated as empty, not an error
  missing-directory-returns-empty-attrs =
    myLib.discoverUserRegistry ./fixtures/does-not-exist-discover-user-registry == { };
}
