{
  pkgs,
  kernel,
  initramfs,
  dtb,
}:
{
  kernelParams ? [ ],
  extraBootconfig ? [ ],
}:
let
  inherit (pkgs) lib runCommand;
  tools = pkgs.buildPackages.android-tools;
  key = ../avb-test-key.pem;
  bootScript = ../mkbootimg;
  vendorScript = ../mkvendorbootimg;
  digest =
    values: builtins.hashString "sha256" (builtins.unsafeDiscardStringContext (builtins.toJSON values));
  # Derive identifiers from the complete boot inputs. Neither ID depends on a
  # NixOS toplevel or on the output of an image that embeds the ID.
  kernelId = digest [
    kernel.outPath
    kernel.modules.outPath
    tools.outPath
    (builtins.hashFile "sha256" bootScript)
    (builtins.hashFile "sha256" key)
    kernelParams
  ];
  vendorId = digest [
    initramfs.outPath
    dtb.outPath
    tools.outPath
    (builtins.hashFile "sha256" vendorScript)
    (builtins.hashFile "sha256" key)
    extraBootconfig
  ];
  image =
    name: body:
    runCommand "zhiyu-${name}"
      {
        nativeBuildInputs = [
          pkgs.cpio
          pkgs.gzip
          pkgs.openssl
        ];
        KEY = key;
        MKBOOTIMG = "${tools}/bin/mkbootimg";
        AVBTOOL = "${tools}/bin/avbtool";
        UNPACK = "${tools}/bin/unpack_bootimg";
        SOURCE_DATE_EPOCH = "1";
        AVB_SALT = digest [
          "zhiyu-avb-v1"
          name
        ];
      }
      ''
        export OUT="$out"
        ${body}
      '';
  boot = image "boot" ''
    export KERNEL=${kernel}/Image
    export EXTRA_CMDLINE=${
      lib.escapeShellArg (lib.concatStringsSep " " (kernelParams ++ [ "zhiyu.kernel_id=${kernelId}" ]))
    }
    bash ${bootScript}
    rm "$out/boot-none.img"
  '';
  vendorBoot = image "vendor-boot" ''
    export DTB=${dtb}/lenovo-zhiyu.dtb DTS=/dev/null
    export RAMDISK=${initramfs}/initramfs.cpio.gz BOOTCONFIG="$PWD/bootconfig"
    cat ${bootconfig} > "$BOOTCONFIG"
    bash ${vendorScript}
  '';
  bootconfig = pkgs.writeText "zhiyu-bootconfig" (
    lib.concatLines (
      [
        "no_console_suspend"
        "pm_debug_messages"
      ]
      ++ extraBootconfig
      ++ [ ''zhiyu.vendor_id = "${vendorId}"'' ]
    )
  );
  initBoot = image "init-boot" ''
    bash ${../mkinitbootimg}
  '';
  vbmeta = image "vbmeta" ''
    mkdir "$out" work
    export OUT="$PWD/work"
    ln -s ${boot}/boot.img "$OUT/boot-none.img"
    ln -s ${vendorBoot}/vendor_boot.img "$OUT/vendor_boot.img"
    ln -s ${initBoot}/init_boot.img "$OUT/init_boot.img"
    bash ${../mkvbmetaimg}
    mv "$OUT/vbmeta.img" "$out/"
  '';
  bundle = image "images" ''
    mkdir "$out"
    cd "$out"
    ln -s ${boot}/boot.img .
    ln -s ${vendorBoot}/vendor_boot.img .
    ln -s ${initBoot}/init_boot.img .
    ln -s ${vbmeta}/vbmeta.img .
    bash ${../scripts/verify-images.sh} --bundle "$out" ${kernel.configfile}
    sha256sum *.img > SHA256SUMS
    for part in *.img; do printf '%s %s\n' "$(stat -Lc %s "$part")" "$part"; done > SIZES
    printf '%s\n' '${kernelId} ${vendorId}' > BOOT-IDS
  '';
in
assert lib.all (
  p:
  !(
    lib.hasInfix "zhiyu.kernel_id" p
    || lib.hasInfix "zhiyu.vendor_id" p
    || lib.hasInfix "androidboot.slot_suffix" p
  )
) (kernelParams ++ extraBootconfig);
{
  inherit kernelId vendorId;
  packages = {
    android-image-tools = tools;
    zhiyu-boot = boot;
    zhiyu-vendor-boot = vendorBoot;
    zhiyu-init-boot = initBoot;
    zhiyu-vbmeta = vbmeta;
    zhiyu-images = bundle;
  };
}
