# alice's home-manager configuration. Registered under the plain key
# "alice", so it applies on every host that has no `alice@...` entry.
# This file is yours to fill in.
{ ... }:
{
  # Pin stateVersion to the release this home was FIRST created with and
  # never bump it casually -- leaving it unset makes it follow the
  # current nixpkgs release (and warns).
  home.stateVersion = "26.11";
}
