# Mechanical integrity checks for the documentation, in the spirit of
# "things that are enforced, not remembered" (docs/architecture.md).
#
# The two pre-existing doc checks pin NAMES -- allowlist-documented
# compares argument bullets against allowedDefaultArgs, and
# ext-options-documented-in-guide compares the guide's option table
# against the declared options. Both stayed green through two rounds of
# genuinely wrong documentation, because nothing pinned the things below:
# examples that no longer parse, references to functions that no longer
# exist, `#anchor` links to headings that were renamed, and doc-comment
# indentation (a stray re-indent silently turned a whole section of
# docs/lib.md into a Markdown code block).
#
# Every rule here is MECHANICAL. Whether a paragraph is *true* still
# needs a human -- these only stop the classes a machine can settle.
{ pkgs, self }:
let
  inherit (pkgs) lib;
in
pkgs.runCommand "docs-integrity"
  {
    nativeBuildInputs = [ pkgs.python3 ];
    src = self;
  }
  ''
    cp -r "$src" repo && chmod -R +w repo && cd repo
    python3 ${./scripts/docs-integrity.py}
    touch $out
  ''
