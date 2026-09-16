# A REAL builder argument, but not one a user's own file may set --
# cycle 9. `rootPath` is rejected specifically because it is circular
# (it would move the lookup of this very file).
{
  rootPath = ./.;
}
