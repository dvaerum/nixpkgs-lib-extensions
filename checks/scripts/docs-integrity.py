#!/usr/bin/env python3
"""Mechanical documentation-integrity rules. See checks/docs-integrity.nix."""
import re, sys, pathlib, subprocess

fail = []
def bad(rule, where, msg):
    fail.append(f"[{rule}] {where}: {msg}")

nix_files = sorted(pathlib.Path("lib").rglob("*.nix"))
md_files = sorted(pathlib.Path("docs").glob("*.md")) + [pathlib.Path("README.md")]
# Prose that narrates behaviour outside lib/ -- comments in tests and the
# check scripts themselves -- can carry the same stale-name mistake.
# Scoped to `checks/` (excluding fixtures/invalid-fixtures/example, which
# are DATA trees the library scans, not narration -- they hold deliberately
# dangling symlinks and non-UTF-8 fixtures that aren't readable as text at
# all) and `scripts/`. Still requires a backtick (see RULE 3 below for why
# bare-word matching is unsafe here: these directories' test fixtures
# legitimately use old argument names as bare Nix identifiers, to prove
# they're now rejected).
_fixture_dirs = ("checks/fixtures/", "checks/invalid-fixtures/", "checks/example/")
prose_files = (
    md_files + nix_files
    + [
        p for p in sorted(pathlib.Path("checks").rglob("*.nix"))
        if not str(p).startswith(_fixture_dirs) and p.is_file()
    ]
    + sorted(pathlib.Path("scripts").rglob("*.sh"))
)

# ---------------------------------------------------------------- doc comments
# (file, start_line, body_lines) for every /** */ block under lib/
def doc_blocks():
    for f in nix_files:
        lines = f.read_text().split("\n")
        start = None
        for i, l in enumerate(lines):
            if l.strip() == "/**":
                start = i
            elif l.strip() == "*/" and start is not None:
                yield f, start + 1, lines[start + 1 : i]
                start = None

# RULE 1 -- consistent indentation inside a doc comment.
# nixdoc dedents relative to the FIRST content line, then the result is
# rendered as Markdown: a line landing SHALLOWER than that breaks the
# dedent outright, and one landing 4+ columns DEEPER (relative to the
# block's own nesting -- a bare list item and its wrapped continuation
# both sit a couple of columns deeper than the block's base and that is
# normal) crosses Markdown's own indented-code-block threshold and
# renders the rest of the paragraph as a code block. Both directions are
# real: the incident that motivated this rule was a splice that pushed
# `readIfPlainOr`'s prose 4 columns deeper, not shallower.
# Fenced ```...``` examples are exempt -- their content is genuinely
# indented on purpose and Markdown already treats it as one block.
for f, ln, body in doc_blocks():
    content = [l for l in body if l.strip()]
    if not content:
        continue
    base = len(content[0]) - len(content[0].lstrip())
    in_fence = False
    for off, l in enumerate(body):
        stripped = l.strip()
        if stripped.startswith("```"):
            in_fence = not in_fence
            continue
        if not stripped or in_fence:
            continue
        ind = len(l) - len(l.lstrip())
        if ind < base:
            bad("doc-indent", f"{f}:{ln + off + 1}",
                f"indented {ind} < first content line's {base}; nixdoc "
                f"dedents by the first line, so this renders wrong")
            break
        if ind - base >= 4:
            bad("doc-indent", f"{f}:{ln + off + 1}",
                f"indented {ind - base} columns deeper than the block's own "
                f"base ({base}) -- Markdown reads 4+ extra columns as a "
                f"code block, silently swallowing the rest of the section")
            break

# RULE 2 -- inside a ```nix fenced block, a `${...}` within a Nix '' ''
# string must be escaped as ''${...} when meant literally (a shell
# variable, a systemd specifier). Unescaped, Nix reads it as
# antiquotation, so the example is a parse error the moment a reader
# copies it -- exactly what shipped in interceptingWrapper's docs.
# Scoped to fenced examples, wherever they live: lib/ doc comments AND
# README.md/docs/*.md, which carry independently-authored examples of
# their own (a prior version of this rule covered lib/ only and missed
# the identical bug sitting in README.md's own example).
#
# Deliberately NOT "every example must parse": examples legitimately use
# `=>` result lines, `<placeholder>` syntax and relative paths that no
# wrapper can make parse, so that rule produces false positives -- and a
# noisy gate gets ignored, which is worse than no gate.
def nix_fences(text):
    for blk in re.finditer(r"```nix\n(.*?)```", text, re.S):
        yield blk.start(1), blk.group(1)

def check_antiquotation(f, text, line_of):
    for base, code in nix_fences(text):
        for sm in re.finditer(r"''(.*?)''", code, re.S):
            inner, off = sm.group(1), sm.start(1)
            for m in re.finditer(r"\$\{", inner):
                if inner[max(0, m.start() - 2) : m.start()] == "''":
                    continue
                bad("doc-example-antiquotation", f"{f}:{line_of(base + off + m.start())}",
                    "unescaped ${...} inside a '' '' string in an example -- "
                    "write ''${...}, or it is a parse error when copied")

for f, ln, body in doc_blocks():
    text = "\n".join(body)
    check_antiquotation(f, text, lambda pos, text=text, ln=ln: ln + text[:pos].count("\n") + 1)
for f in md_files:
    text = f.read_text()
    check_antiquotation(f, text, lambda pos, text=text: text[:pos].count("\n") + 1)

# RULE 3 -- no doc, comment or test narration may still name a function
# that was deleted from the library in a past refactor. This is
# DELIBERATELY a fixed, hand-maintained list, not a general "every
# backticked name must be a real lib attribute" check: that was tried --
# a name is `real` if it is a top-level lib definition, `allowed` adds
# argument/vocabulary names on top, and even with both sets populated
# dynamically it still flagged three dozen legitimate backticked names
# (nixpkgs builtins, local `let` bindings, NixOS option names) that were
# never lib functions and never claimed to be one. A gate that noisy
# gets ignored, which is worse than no gate -- so this stays scoped to
# names KNOWN to have existed and been removed.
#
# Requires a backtick, and does NOT match a bare identifier: `checks/`
# test fixtures legitimately use some of these exact names as bare Nix
# argument keys, specifically to prove the builder now REJECTS them --
# matching bare words would flag that legitimate usage as if it were a
# stale doc claim.
deleted = {"userRegistry","resolveUserRegistry","matchedEntries","validateRegistryKeys",
           "stringPathEntryWarning","badRegistryKey","homesFromPlan"}
for f in prose_files:
    txt = f.read_text()
    for m in re.finditer(r"`([a-z][A-Za-z0-9]{3,})`", txt):
        name = m.group(1)
        if name in deleted:
            line = txt[:m.start()].count("\n") + 1
            bad("no-deleted-names", f"{f}:{line}",
                f"`{name}` was removed from the library")

# RULE 4 -- every `file.md#anchor` link resolves to a real heading.
# Anchors are matched case-insensitively (Markdown heading slugs are
# lowercased by every renderer this repo's docs target) so a capitalised
# typo in the link doesn't slip past the same check that catches a
# lowercase one.
def slugs(path):
    out = set()
    for l in pathlib.Path(path).read_text().split("\n"):
        if l.startswith("#"):
            h = l.lstrip("#").strip()
            out.add(re.sub(r"[^a-z0-9 -]", "", h.lower()).replace(" ", "-"))
    return out
slug_cache = {}
for f in md_files + nix_files:
    txt = f.read_text()
    for m in re.finditer(r"([A-Za-z0-9_./-]+\.md)#([a-zA-Z0-9-]+)", txt):
        target, anchor = m.group(1), m.group(2).lower()
        cands = [pathlib.Path("docs") / pathlib.Path(target).name, pathlib.Path(target)]
        tp = next((c for c in cands if c.exists()), None)
        line = txt[:m.start()].count("\n") + 1
        if tp is None:
            bad("anchor-resolves", f"{f}:{line}", f"link target {target} does not exist")
            continue
        if str(tp) not in slug_cache:
            slug_cache[str(tp)] = slugs(tp)
        if anchor not in slug_cache[str(tp)]:
            bad("anchor-resolves", f"{f}:{line}",
                f"{target}#{anchor} -- no heading with that slug")

# RULE 4b -- same-FILE `](#anchor)` links (no .md prefix) resolve too.
# These are the common kind in a long guide, and the cross-file rule
# above cannot see them.
for f in md_files:
    txt = f.read_text()
    if str(f) not in slug_cache:
        slug_cache[str(f)] = slugs(f)
    for m in re.finditer(r"\]\(#([a-zA-Z0-9-]+)\)", txt):
        anchor = m.group(1).lower()
        if anchor not in slug_cache[str(f)]:
            line = txt[:m.start()].count("\n") + 1
            bad("anchor-resolves", f"{f}:{line}",
                f"#{anchor} -- no heading with that slug in this file")

# RULE 5 -- filenames the docs tell you to put in a patches/ directory must
# have an extension discoverPatches actually accepts, or the directory form
# silently skips them. Scans lib/ doc comments too, not just docs/*.md --
# the recipe is just as wrong wherever it is written.
for f in md_files + nix_files:
    txt = f.read_text()
    for m in re.finditer(r"patches/([A-Za-z0-9._-]+)", txt):
        name = m.group(1)
        if "." not in name or name.endswith((".patch", ".nix", ".disabled", ".md")):
            continue
        line = txt[:m.start()].count("\n") + 1
        bad("patches-suffix", f"{f}:{line}",
            f"patches/{name}: discoverPatches only applies .patch/.nix, so a "
            f"`patches = [ ./patches ]` directory would skip this with a warning")

if fail:
    print("docs-integrity: %d problem(s)\n" % len(fail), file=sys.stderr)
    for x in fail:
        print("  - " + x, file=sys.stderr)
    sys.exit(1)
print("docs-integrity: all rules pass")
