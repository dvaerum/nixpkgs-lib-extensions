# A fixture that plays the role of a REAL cross-flake `loginFlakeRef`
# source (like home-manager-config) for checks/builders/tests/
# login-context.nix: it needs its OWN `rootPath` (the marker import
# below), its OWN `specialArgs` (sourceMarker) and its OWN auto-collected
# home-manager modules (SOURCE_AUTO_MODULE_MARKER, from a fake input only
# present in the loginContext's `inputs`, never the consumer's) to build
# at all -- exactly the three ways the reported bug broke.
{
  rootPath,
  sourceMarker ? null,
  ...
}:
{
  imports = [ (rootPath + /marker/default.nix) ];
  home.username = "dennis";
  home.homeDirectory = "/home/dennis";
  home.stateVersion = "24.05";
  home.sessionVariables.SOURCE_SPECIALARG_MARKER = sourceMarker;
}
