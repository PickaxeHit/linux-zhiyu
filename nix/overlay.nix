final: prev:
let
  sources = import ./sources.nix { pkgs = prev; };
  bsp = import ./packages.nix {
    pkgs = final;
    cameraBase = prev.libcamera;
    inherit sources;
  };
  abi = prev.lib.versions.majorMinor prev.libcamera.version;
in
{
  zhiyu = bsp;
  libcamera =
    if !prev.stdenv.hostPlatform.isAarch64 then
      prev.libcamera
    else
      {
        "0.7" = bsp.packages.libcamera-0_7;
        "0.8" = bsp.packages.libcamera-0_8;
      }
      .${abi} or (throw "zhiyu libcamera supports nixpkgs libcamera ABIs 0.7 and 0.8, found ${abi}");
}
