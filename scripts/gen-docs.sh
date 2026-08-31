# gen-docs: build docs/lib.md from the doc comments in lib/.
#
# Wrapped by writeShellApplication in flake.nix -- runtime inputs, a pass
# through shellcheck, and the docs-up-to-date check that diffs its output
# against docs/lib.md are wired there. (Comment worded so no line here
# starts with "shellcheck": that would misparse as a shellcheck directive
# and break the build with SC1072/SC1073, as trimming this exact comment
# once did.)

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

# A page this long (every function's doc comment, one after another) is
# unnavigable without a table of contents -- GitHub does not synthesize
# one for plain markdown on its own. Built from the BODY's own headings
# after to_plain_markdown, so it can never drift from what is actually on
# the page. Anchors are computed with GitHub's own slug rule (lowercase;
# drop everything but letters/digits/spaces/hyphens/underscores, which
# removes the backticks AND the periods in `lib.foo.bar`; spaces become
# hyphens) -- not nixdoc's `{#sec-...}` ids, which to_plain_markdown
# already strips because GitHub ignores them and slugs the heading text
# itself instead.
make_toc() {
  awk '
    function slugify(text,    s) {
      s = tolower(text)
      gsub(/[^a-z0-9 _-]/, "", s)
      gsub(/ /, "-", s)
      return s
    }
    # a Nix comment inside an Example fence ("# like this") starts with
    # the same character as a markdown heading -- only headings OUTSIDE
    # a ``` fence count
    /^```/ { fenced = !fenced; next }
    fenced { next }
    /^# / {
      text = substr($0, 3)
      print "- [" text "](#" slugify(text) ")"
      next
    }
    /^## / {
      text = substr($0, 4)
      print "  - [" text "](#" slugify(text) ")"
      next
    }
  '
}

# One `---` between top-level namespace sections (attrsets / disko /
# imports / nixos / ...), not before the very first -- pure visual
# breathing room on an otherwise unbroken run of headings. Same fence
# tracking as make_toc, for the same reason (a fenced "# comment" is not
# a namespace heading).
add_separators() {
  awk '
    /^```/ { fenced = !fenced; print; next }
    fenced { print; next }
    /^# / { if (seen++) print "---\n" }
    { print }
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
  body="$(
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
  )"
  echo "## Contents"
  echo
  make_toc <<<"$body"
  echo
  add_separators <<<"$body"
} > docs/lib.md
