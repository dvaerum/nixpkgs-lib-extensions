# gen-docs: build docs/lib.md from the doc comments in lib/.
#
# Wrapped by writeShellApplication in flake.nix, which provides the
# runtime inputs (coreutils, gawk, nixdoc) and shellcheck-verifies this
# file at build time. The docs-up-to-date flake check runs this exact
# script and diffs the result against the committed docs/lib.md.

# nixdoc targets the NixOS manual toolchain; plain-markdown viewers
# (GitHub included) need its output converted. One linear pass:
# - repeated per-file category headers (# <folder> {#sec-...}) are
#   dropped after their first occurrence (nixdoc emits one per FILE,
#   the reference wants one per folder)
# - definition lists ("term" line + ": ..." lines) become bulleted
#   terms with indented descriptions; a bare ":" line is a paragraph
#   separator inside a description
# - {#anchor} heading attributes are stripped (GitHub renders them
#   literally and derives its own anchors from the heading text)
# Deciding whether a line is a term needs one line of lookahead, so
# lines are emitted one step behind reading, via flush().
to_plain_markdown() {
  awk '
    function flush(next_line) {
      if (!have) return
      if (prev_fence || prev ~ /^```/) { print prev; return }
      if (prev ~ /^# [^{]+\{#sec-functions-library[^}]+\}$/) {
        if (seen[prev]++) return
        sub(/ \{#[^}]+\}$/, "", prev); print prev; return
      }
      if (prev != "" && prev != ":" && prev !~ /^: / && next_line ~ /^: /) {
        print "- **" prev "**"; return
      }
      if (prev ~ /^: ?/) { sub(/^: ?/, "", prev); print "  " prev; return }
      if (prev ~ /^#+ .*[^ ] \{#[^}]+\}$/) sub(/ \{#[^}]+\}$/, "", prev)
      print prev
    }
    {
      cur = $0
      cur_fence = fenced
      if (cur ~ /^```/) fenced = !fenced
      flush(cur)
      prev = cur; prev_fence = cur_fence; have = 1
    }
    END { flush("") }
  '
}

{
  cat <<'EOF'
# Library reference

Generated from the doc comments in `lib/` -- do not edit by hand;
run `nix run .#gen-docs` after changing a doc comment. New to the
builders? Start with the
[getting-started guide](getting-started.md).

EOF
  find lib -iname "*.nix" -type f | sort -V | while read -r nix_file; do
    [[ "$nix_file" == "lib/default.nix" ]] && continue
    # internal helper files are not part of the public lib
    [[ "$nix_file" == */internal/* ]] && continue

    folder_name="$(basename "$(dirname "$nix_file")")"
    nixdoc --category "$folder_name" \
           --description "$folder_name" \
           --anchor-prefix "" \
           --file "$nix_file"
  done | to_plain_markdown
} > docs/lib.md
