# Vendored: nix-mustache

`default.nix` in this directory is vendored from
[valodzka/nix-mustache](https://github.com/valodzka/nix-mustache),
commit [`1155eeb0cbe33a448ceb3e9c4fb1583491ec79a5`](https://github.com/valodzka/nix-mustache/commit/1155eeb0cbe33a448ceb3e9c4fb1583491ec79a5)
(2024-03-28), copied on 2026-10-04. MIT licensed -- full license text
in `LICENSE.txt`, copyright (c) 2024 Valodzka.

Written by GitHub user [valodzka](https://github.com/valodzka), who
posted it to NixOS Discourse in March 2024 as their first non-trivial
Nix program. It implements the full core Mustache spec plus lambdas
and was tested against the real upstream
[mustache/spec](https://github.com/mustache/spec) suite. We're
grateful it exists, and specifically that it's a genuinely *pure* Nix
implementation rather than a wrapper around an external renderer:
that avoids Import-From-Derivation entirely (rendering a template
never needs a build just to read its own output back into Nix),
which is exactly the performance trap a derivation-based templating
approach would otherwise walk into.

Vendored rather than pulled in as a flake input: it's a single
~270-line file, feature-complete, and has had zero issues or PRs
since that commit. Depending on it as a live flake input would add a
transitive input, for every consumer of this library, on a
single-maintainer repo with very low adoption (6 stars) -- vendoring
removes any risk of that repo disappearing or going stale out from
under us, at the cost of us owning any future fix ourselves.

`default.nix` is kept byte-identical to upstream (excluded from this
repo's nixfmt check, in `flake.nix`'s `fmtFor`) so a future re-vendor
is a straight content diff against upstream, not tangled with
nixfmt's own style churn.
