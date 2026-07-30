# Fails when any .nix file in the tree is not nixfmt-formatted.
#
# The tree was nixfmt-ish but never actually nixfmt-clean, because nothing
# enforced it -- drift stayed invisible until someone reformatted a file and
# the diff exploded. Runs the exact same script as `nix fmt` (the flake's
# formatter output), just with --check, so there is no second copy of the
# "which files" logic to drift -- mirroring gen-docs / docs-up-to-date.
{
  pkgs,
  self,
  fmt,
}:
pkgs.runCommand "formatting" { } ''
  cd ${self}
  if ! ${fmt}/bin/fmt --check; then
    echo >&2
    echo "the files above are not nixfmt-formatted; run: nix fmt" >&2
    exit 1
  fi
  touch $out
''
