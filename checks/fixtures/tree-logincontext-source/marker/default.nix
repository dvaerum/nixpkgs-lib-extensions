# A module reachable ONLY through THIS tree's own `rootPath` -- checks/
# builders/tests/login-context.nix imports it via `(rootPath + /marker/
# default.nix)` from dennis's home.nix. If a `loginFlakeRef` consumer's
# own rootPath were used instead (the bug), this path would not exist.
{ ... }:
{
  home.sessionVariables.SOURCE_ROOTPATH_MARKER = "reached-via-source-rootpath";
}
