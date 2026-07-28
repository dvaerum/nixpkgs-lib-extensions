# Full instantiation: force the derivations, not just option reads.
{
  laptop,
  server,
  aliceHome,
  ...
}:
{
  # instantiating the full system forces NixOS assertions/warnings that
  # option-level reads skip
  laptop-toplevel-instantiates = builtins.isString laptop.config.system.build.toplevel.drvPath;
  server-toplevel-instantiates = builtins.isString server.config.system.build.toplevel.drvPath;
  # proves the home configuration can actually produce its activation
  # package, not just evaluate options
  alice-home-activation-instantiates = builtins.isString aliceHome.activationPackage.drvPath;
}
