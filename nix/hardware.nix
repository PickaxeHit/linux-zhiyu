{ pkgs, sources }:
let
  inherit (pkgs) lib runCommand;
  raw = sources.firmware.src;
  # alsatplg needs neither the ALSA runtime plugins nor PipeWire.
  topologyTools = pkgs.alsa-utils.override {
    alsa-plugins = runCommand "zhiyu-no-alsa-plugins" { } ''mkdir -p "$out/lib/alsa-lib"'';
    withPipewireLib = false;
  };
  copyFirmware = ''
    mkdir -p "$out/lib/firmware" "$out/share/licenses/zhiyu-firmware"
    cp -a ${raw}/firmware/. "$out/lib/firmware/"
    cp ${raw}/{LICENSE.qcom,LICENSE.qcom-2,NOTICE.qcom} "$out/share/licenses/zhiyu-firmware/"
  '';
in
rec {
  firmware-blobs = runCommand "zhiyu-firmware-blobs-${sources.firmware.version}" { } copyFirmware;
  topology =
    runCommand "zhiyu-audioreach-topology"
      {
        nativeBuildInputs = [
          pkgs.m4
          topologyTools
        ];
      }
      ''
        export OUT="$out/lib/firmware/qcom/sm8750/sm8750-tplg.bin"
        export AUDIOREACH_SRC=${sources.audioreach.src}
        bash ${../initramfs-src/tplg}/build.sh
      '';
  firmware = runCommand "zhiyu-firmware-${sources.firmware.version}" { } ''
    mkdir -p "$out/lib"
    cp -R ${firmware-blobs}/. "$out/"
    chmod u+w "$out/lib/firmware"/{qcom,qcom/sm8750}
    cp ${topology}/lib/firmware/qcom/sm8750/sm8750-tplg.bin "$out/lib/firmware/qcom/sm8750/"
  '';
  sns = runCommand "zhiyu-sns-${sources.firmware.version}" { } ''
    mkdir -p "$out/share/qcom" "$out/share/licenses/zhiyu-sns"
    cp -a ${raw}/sensors "$out/share/qcom/"
    cp ${raw}/{LICENSE.qcom,LICENSE.qcom-2,NOTICE.qcom} "$out/share/licenses/zhiyu-sns/"
  '';
  ucm2 = runCommand "zhiyu-alsa-ucm2" { } ''
    mkdir -p "$out/share/alsa/ucm2"
    cp -r ${pkgs.alsa-ucm-conf}/share/alsa/ucm2/. "$out/share/alsa/ucm2/"
    chmod -R u+w "$out/share/alsa/ucm2"
    cp -r ${../scripts/alsa-ucm2}/. "$out/share/alsa/ucm2/"
  '';
  udev-rules = runCommand "zhiyu-udev-rules" { } ''
    install -Dm644 ${../scripts/60-persistent-v4l.rules} "$out/lib/udev/rules.d/60-persistent-v4l.rules"
    install -Dm644 ${../scripts/90-fastrpc.rules} "$out/lib/udev/rules.d/90-fastrpc.rules"
    install -Dm644 ${../scripts/90-dma-heap.rules} "$out/lib/udev/rules.d/90-dma-heap.rules"
    substitute ${../scripts/91-flash-led.rules} "$out/lib/udev/rules.d/91-flash-led.rules" \
      --replace-fail /bin/chmod ${pkgs.coreutils}/bin/chmod
    install -Dm644 ${../configs/modprobe.d/99-zhiyu-no-trace.conf} "$out/lib/modprobe.d/99-zhiyu-no-trace.conf"
  '';
  qcom-va-driver = pkgs.stdenv.mkDerivation {
    pname = "qcom-va-driver";
    inherit (sources.qcom-va-driver) src version;
    nativeBuildInputs = [
      pkgs.meson
      pkgs.ninja
      pkgs.pkg-config
    ];
    buildInputs = [
      pkgs.libva
      pkgs.libdrm
      pkgs.libglvnd
      pkgs.libgbm
    ];
    mesonFlags = [
      "-Dgpu_copy=enabled"
      "-Dcdsp_vpp=disabled"
      "-Dvulkan_vpp=disabled"
    ];
  };
  hexagonrpc = pkgs.hexagonrpc.overrideAttrs {
    inherit (sources.hexagonrpc) src version;
  };
  sensh = pkgs.stdenv.mkDerivation {
    pname = "sensh";
    inherit (sources.sensh) src version;
    nativeBuildInputs = [
      pkgs.meson
      pkgs.ninja
      pkgs.pkg-config
      pkgs.protobufc
      pkgs.qmic
    ];
    buildInputs = [
      pkgs.protobufc
      pkgs.qrtr
    ];
    strictDeps = true;
  };
  sensord = pkgs.stdenv.mkDerivation {
    name = "zhiyu-sensord";
    src = lib.fileset.toSource {
      root = ../sensors;
      fileset = lib.fileset.unions [
        ../sensors/sensord.c
        ../sensors/Makefile
      ];
    };
    strictDeps = true;
    nativeBuildInputs = [ pkgs.pkg-config ];
    buildInputs = [ pkgs.glib ];
    postPatch = ''
      substituteInPlace sensord.c \
        --replace-fail '/usr/local/bin/sensh' '${sensh}/bin/sensh' \
        --replace-fail '/usr/bin/stdbuf' '${pkgs.coreutils}/bin/stdbuf' \
        --replace-fail '/usr/bin/systemd-notify' '${pkgs.systemd}/bin/systemd-notify'
    '';
    installPhase = ''
      runHook preInstall
      install -Dm755 sensord "$out/bin/zhiyu-sensord"
      install -Dm644 ${./sensord-dbus.conf} "$out/share/dbus-1/system.d/zhiyu-sensord.conf"
      runHook postInstall
    '';
  };
}
