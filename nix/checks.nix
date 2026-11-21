{
  pkgs,
  bsp,
  cfg,
}:
let
  inherit (pkgs) runCommand;
  p = bsp.packages;
  camera = cfg.system.build.zhiyuCamera;
  cameraReplacements = cfg.system.replaceDependencies.replacements;
  cameraReplacement = builtins.head cameraReplacements;
  kernel = cfg.boot.kernelPackages.kernel;
  imagesWithCmdline = bsp.mkImages p.kernel { kernelParams = [ "lsm=landlock,yama" ]; };
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
    assert cfg.system.build.zhiyuPipewire.drvPath == pkgs.pipewire.drvPath;
    assert camera.upstream.drvPath == pkgs.libcamera.drvPath;
    assert camera.fork.drvPath == p.libcamera.drvPath;
    assert camera.fork.drvPath != camera.upstream.drvPath;
    assert builtins.length cameraReplacements == 1;
    assert cameraReplacement.oldDependency.drvPath == camera.upstream.drvPath;
    assert cameraReplacement.newDependency.name == camera.upstream.name;
    runCommand "zhiyu-evaluation" { } "touch $out";
  camera-runtime = runCommand "zhiyu-camera-runtime-test" { } ''
    test "$(readlink ${cameraReplacement.newDependency})" = "${camera.fork}"
    touch "$out"
  '';
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
