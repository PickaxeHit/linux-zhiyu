{
  pkgs,
  p,
  cfg,
}:
let
  inherit (pkgs) runCommand;
  kernel = cfg.boot.kernelPackages.kernel;
  imagesWithCmdline = pkgs.zhiyu.mkImages p.kernel { kernelParams = [ "lsm=landlock,yama" ]; };
  image = imagesWithCmdline.packages;
  simulator = pkgs.callPackage ./flasher.nix { simulate = true; };
in
{
  inherit (p)
    libcamera-0_7
    libcamera-0_8
    sensord
    sensh
    hexagonrpc
    ;
  images = p.zhiyu-images;
  external-module = pkgs.stdenv.mkDerivation {
    name = "zhiyu-test-external-module";
    nativeBuildInputs = [ pkgs.kmod ] ++ kernel.moduleBuildDependencies;
    buildCommand = ''
      cat > test.c <<'C'
      #include <linux/module.h>
      static int __init hello_init(void) { return 0; }
      static void __exit hello_exit(void) {}
      module_init(hello_init);
      module_exit(hello_exit);
      MODULE_LICENSE("GPL");
      C
      echo 'obj-m := test.o' > Makefile
      make -C "${kernel.dev}/lib/modules/${kernel.modDirVersion}/build" M="$PWD" ARCH=arm64 LOCALVERSION= modules
      test "$(modinfo -F vermagic test.ko | cut -d' ' -f1)" = "${kernel.modDirVersion}"
      touch "$out"
    '';
  };
  evaluation =
    assert kernel.drvPath == p.kernel.drvPath;
    assert cfg.system.build.zhiyuFirmware.drvPath == p.firmware.drvPath;
    assert cfg.system.build.zhiyuInitramfs.drvPath == p.initramfs.drvPath;
    assert cfg.system.build.zhiyuImages.drvPath != p.zhiyu-images.drvPath;
    assert !cfg.zhiyu.flashOnSwitch;
    assert cfg.boot.loader.external.installHook == "${cfg.system.build.installBootLoader}";
    assert image.zhiyu-boot.drvPath != p.zhiyu-boot.drvPath;
    assert image.zhiyu-vendor-boot.drvPath == p.zhiyu-vendor-boot.drvPath;
    assert image.zhiyu-init-boot.drvPath == p.zhiyu-init-boot.drvPath;
    assert image.zhiyu-vbmeta.drvPath != p.zhiyu-vbmeta.drvPath;
    assert builtins.any (
      input: (input.pname or "") == "libcamera-zhiyu" && input.drvPath == pkgs.libcamera.drvPath
    ) cfg.system.build.zhiyuPipewire.buildInputs;
    runCommand "zhiyu-evaluation" { } "touch $out";
  boot-tools =
    runCommand "zhiyu-boot-tools-test"
      {
        nativeBuildInputs = [ pkgs.python3 ];
        passthru = { inherit simulator; };
      }
      ''
        python3 ${./test-boot.py} ${p.static-helpers}/bin/zhiyu-boot-select \
          ${simulator}/bin/zhiyu-install ${p.flasher}/bin/zhiyu-install
        touch "$out"
      '';
}
