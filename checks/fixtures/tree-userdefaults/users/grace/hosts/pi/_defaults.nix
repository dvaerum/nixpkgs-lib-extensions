# host layer -- `extra.homeModules` ADDS to the base list rather than
# replacing it (cycle 10).
{
  extra.homeModules = [ ./marker-extra.nix ];
}
