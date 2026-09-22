# Proves `users/<u>/_defaults.nix` gets the SAME loginContext override
# home.nix/configuration.nix already get: `_defaults.nix` predates the
# loginContext feature and was never updated when it shipped, so its
# `contextFor` (hosts-args.nix) always passed the CONSUMER's own
# rootPath/inputs -- same bug class, found by cross-checking every
# OTHER place a discovered user's own file resolves `rootPath`.
{ rootPath, ... }:
{
  homeModules = [ (rootPath + /marker/default.nix) ];
}
