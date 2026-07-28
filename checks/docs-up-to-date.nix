# Fails when docs/lib.md is stale, i.e. when regenerating it from the
# current /** */ doc comments produces a different file. Runs the exact
# `gen-docs` tool a developer would run, so there is no second copy of the
# generation logic to drift.
{
  pkgs,
  self,
  gen-docs,
}:
pkgs.runCommand "docs-up-to-date" { } ''
  cp -r ${self}/lib lib
  mkdir docs
  ${gen-docs}/bin/gen-docs

  if ! diff -u ${self}/docs/lib.md docs/lib.md; then
    echo
    echo "docs/lib.md is out of date; run: nix run .#gen-docs" >&2
    exit 1
  fi
  touch $out
''
