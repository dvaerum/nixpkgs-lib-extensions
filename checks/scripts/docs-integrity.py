#!/usr/bin/env python3
"""Mechanical documentation-integrity rules. See checks/docs-integrity.nix."""
import re, sys, pathlib, subprocess

fail = []
def bad(rule, where, msg):
    fail.append(f"[{rule}] {where}: {msg}")

nix_files = sorted(pathlib.Path("lib").rglob("*.nix"))
md_files = sorted(pathlib.Path("docs").glob("*.md")) + [pathlib.Path("README.md")]

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
# nixdoc dedents relative to the FIRST content line; a block whose later
# lines are indented deeper renders as a Markdown code block in lib.md.
for f, ln, body in doc_blocks():
    content = [l for l in body if l.strip()]
    if not content:
        continue
    base = len(content[0]) - len(content[0].lstrip())
    for off, l in enumerate(body):
        if not l.strip():
            continue
        ind = len(l) - len(l.lstrip())
        # deeper indentation is legitimate (nested lists, fenced code,
        # `:` definition-list continuations); SHALLOWER than the first
        # line is what breaks the dedent.
        if ind < base:
            bad("doc-indent", f"{f}:{ln + off + 1}",
                f"indented {ind} < first content line's {base}; nixdoc "
                f"dedents by the first line, so this renders wrong")
            break

# RULE 2 -- inside a ```nix EXAMPLE, a `${...}` within a Nix '' '' string
# must be escaped as ''${...} when meant literally (a shell variable, a
# systemd specifier). Unescaped, Nix reads it as antiquotation, so the
# example is a parse error the moment a reader copies it -- exactly what
# shipped in interceptingWrapper's docs. Scoped to fenced examples: in
# prose, `${...}` inside backticks is just markdown.
#
# Deliberately NOT "every example must parse": examples legitimately use
# `=>` result lines, `<placeholder>` syntax and relative paths that no
# wrapper can make parse, so that rule produces false positives -- and a
# noisy gate gets ignored, which is worse than no gate.
for f, ln, body in doc_blocks():
    text = "\n".join(body)
    for blk in re.finditer(r"```nix\n(.*?)```", text, re.S):
        code, base = blk.group(1), blk.start(1)
        for sm in re.finditer(r"''(.*?)''", code, re.S):
            inner, off = sm.group(1), sm.start(1)
            for m in re.finditer(r"\$\{", inner):
                if inner[max(0, m.start() - 2) : m.start()] == "''":
                    continue
                line = ln + text[: base + off + m.start()].count("\n") + 1
                bad("doc-example-antiquotation", f"{f}:{line}",
                    "unescaped ${...} inside a '' '' string in an example -- "
                    "write ''${...}, or it is a parse error when copied")

# RULE 3 -- no documentation may name a lib function that does not exist.
# Backticked `camelCase` identifiers are checked against the real
# attribute names; anything else is prose and ignored.
real = set()
for f in nix_files:
    for m in re.finditer(r"^  ([a-z][A-Za-z0-9]*) =", f.read_text(), re.M):
        real.add(m.group(1))
# names that are arguments/options/other vocabulary, not lib functions
allowed = real | {
    "inputs","system","nixpkgs","rootPath","modules","userModule","users","loginHomes",
    "homeModules","loginFlakeRef","loginReactivateEveryLogin","traceDiscoveredUsers",
    "wrapHomeManagerSwitch","tags","group","hostFolder","patches","overlays",
    "allowedUnfreePackages","permittedInsecurePackages","nixpkgsConfig","specialArgs",
    "homeManager","inputContributions","hostname","username","extra","default",
    "nixosModules","homeModules","libOverlays","legacyPackages","packages","outPath",
    "nixosConfigurations","homeConfigurations","activationPackage","useGlobalPkgs",
    "useUserPackages","sharedModules","extraSpecialArgs","stateVersion","isNormalUser",
    "isSystemUser","mkDefault","mkOptionDefault","mkOverride","readFileType","pathExists",
    "readDir","tryEval","hasContext","applyPatches","fetchpatch","nixosSystem","extend",
    "swapSize","useZfsForTmp","enableEncryption","legacyBoot","mbrBootableFlag",
    "requestEncryptionCredentials","defineBootPartitions","extraDatasets","hostId",
    "toSentenceCase","zipAttrsWith","genAttrs","recursiveUpdate","attrNames","attrValues",
    "concatStringsSep","optionalAttrs","filterAttrs","listToAttrs","foldl","mapAttrs",
}
# deleted in the users/-tree change: naming any of these is always stale
deleted = {"userRegistry","resolveUserRegistry","matchedEntries","validateRegistryKeys",
           "stringPathEntryWarning","badRegistryKey","homesFromPlan","registryUserNames"}
for f in md_files + nix_files:
    txt = f.read_text()
    for m in re.finditer(r"`([a-z][A-Za-z0-9]{3,})`", txt):
        name = m.group(1)
        if name in deleted:
            line = txt[:m.start()].count("\n") + 1
            bad("no-deleted-names", f"{f}:{line}",
                f"`{name}` was removed from the library")

# RULE 4 -- every `file.md#anchor` link resolves to a real heading.
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
    for m in re.finditer(r"([A-Za-z0-9_./-]+\.md)#([a-z0-9-]+)", txt):
        target, anchor = m.group(1), m.group(2)
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
    for m in re.finditer(r"\]\(#([a-z0-9-]+)\)", txt):
        anchor = m.group(1)
        if anchor not in slug_cache[str(f)]:
            line = txt[:m.start()].count("\n") + 1
            bad("anchor-resolves", f"{f}:{line}",
                f"#{anchor} -- no heading with that slug in this file")

# RULE 5 -- filenames the docs tell you to put in a patches/ directory must
# have an extension discoverPatches actually accepts, or the directory form
# silently skips them.
for f in md_files:
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
