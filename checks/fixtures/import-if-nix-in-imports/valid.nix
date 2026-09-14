# The "decryption key is present" case for importIfNix inside an `imports`
# list: a plain, valid NixOS module. A FUNCTION rather than a bare
# attrset, so the test also covers what makes importIfNix's BARE
# `import path` correct -- the module system applies the result itself.
{ lib, ... }:
{
  users.groups.from-import-if-nix = { };
}
