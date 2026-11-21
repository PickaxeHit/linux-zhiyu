{ base, source }:
base.overrideAttrs (old: {
  inherit (source) src version;
  pname = "libcamera-zhiyu";
  mesonFlags = old.mesonFlags ++ [ "-Dpipelines=simple" ];
  meta = old.meta // {
    changelog = "https://github.com/PickaxeHit/libcamera-zhiyu/commit/${source.rev}";
  };
})
