# function form -- cycle 4: must receive `username`/`hostname`/`rootPath`.
# `marker` in specialArgs is read back by the test through the home's own
# _module.specialArgs, which is cheaper to assert than threading a real
# module through homeModules.
{
  inputs,
  rootPath,
  extLib,
  lib,
  username,
  hostname,
  ...
}:
{
  system = "aarch64-linux";
  specialArgs = {
    userDefaultsContextProbe = {
      inherit username hostname;
      gotInputs = inputs ? nixpkgs;
      gotRootPath = rootPath != null;
      gotExtLib = extLib ? mkHomeConfiguration;
      # nixpkgs' plain lib, NOT the module lib -- it must NOT have this
      # library's own additions (e.g. stringToTitle) namespaced onto it.
      gotPlainLib = !(lib ? stringToTitle);
    };
  };
}
