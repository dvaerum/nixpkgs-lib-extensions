# Nested ONE level below home.nix (via a plain relative-path import,
# same as home-manager-config's own users/dennis/imports.nix) -- this
# is where `rootPath`/custom specialArgs actually get used, mirroring
# the real repo exactly. A fix that only overrides args for home.nix
# itself never reaches this file's own arg resolution.
{
  rootPath,
  sourceMarker ? null,
  ...
}:
{
  imports = [ (rootPath + /marker/default.nix) ];
  home.sessionVariables.SOURCE_SPECIALARG_MARKER = sourceMarker;
}
