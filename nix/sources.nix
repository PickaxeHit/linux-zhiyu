{ pkgs }:
let
  locks = builtins.fromJSON (builtins.readFile ../deps/nix-sources.json);
  manifest = builtins.fromJSON (builtins.readFile ../deps/deps.json);
in
builtins.mapAttrs (
  name: spec:
  spec
  // {
    version =
      spec.version
        or (pkgs.lib.removePrefix "v" (manifest.${name}.tag or manifest.${name}.version or spec.rev));
    src =
      if spec.fetcher == "unpacked" then
        pkgs.fetchzip {
          url = spec.archive;
          extension = "tar.gz";
          inherit (spec) hash;
        }
      else if spec.fetcher == "git" then
        pkgs.fetchgit { inherit (spec) url rev hash; }
      else
        pkgs.fetchurl { inherit (spec) url hash; };
  }
) locks
