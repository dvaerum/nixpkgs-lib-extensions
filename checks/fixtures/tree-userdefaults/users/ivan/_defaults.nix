# base layer -- must be REPLACED, not merged, by the host layer's bare
# homeModules below (cycle 10, the other half of grace's ADD case).
{
  homeModules = [ ./marker-base.nix ];
}
