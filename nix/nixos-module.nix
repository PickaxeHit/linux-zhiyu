{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.zhiyu;
  bsp = import ./packages.nix { inherit pkgs; };
  p = bsp.packages;
  camera = {
    upstream = pkgs.libcamera;
    fork = p.libcamera;
  };
  # The closure rewriter requires equal-length store basenames.
  cameraReplacement = pkgs.runCommand camera.upstream.name { } ''
    for lib in libcamera libcamera-base; do
      test -e "${camera.fork}/lib/$lib.so.${camera.upstream.version}"
    done
    ln -s ${camera.fork} "$out"
  '';
  kernel = config.boot.kernelPackages.kernel;
  initramfs = (bsp.mkInitramfs kernel).initramfs;
  images = bsp.mkImages kernel {
    kernelParams = config.boot.kernelParams;
    extraBootconfig = cfg.bootconfig;
  };
  id = pkgs.writeText "zhiyu-boot-id" "${images.kernelId} ${images.vendorId}\n";
  ucm = "${p.ucm2}/share/alsa/ucm2";
  sensorRoot = "/var/lib/zhiyu-qcom";
  adsp = extra: {
    wantedBy = [ "multi-user.target" ];
    after = [
      "systemd-tmpfiles-setup.service"
      "systemd-modules-load.service"
    ];
    restartTriggers = [ p.sns ];
    unitConfig.ConditionPathExists = [
      "!/dev/fastrpc-sdsp"
      "/dev/fastrpc-adsp"
    ];
    serviceConfig = {
      User = "fastrpc";
      Group = "fastrpc";
      ExecStart = "${p.hexagonrpc}/bin/hexagonrpcd -f /dev/fastrpc-adsp -d adsp ${extra} -R ${sensorRoot}";
      Restart = "on-failure";
      RestartSec = 3;
    };
  };
in
{
  options.zhiyu = {
    enable = lib.mkEnableOption "BSP support for Lenovo TB378FC";
    flashOnSwitch = lib.mkEnableOption "writing verified Android images to the running slot on nixos-rebuild boot or switch";
    camera.enable = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Use the ABI-matched Zhiyu libcamera in the system runtime closure.";
    };
    sensors.enable = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Enable FastRPC-backed Zhiyu sensors and the SensorProxy D-Bus service.";
    };
    videoAcceleration = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Install the Qualcomm Iris VA-API driver.";
    };
    bootconfig = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      example = [ "kernel.panic=15" ];
      description = "Additional lines to embed in Android vendor bootconfig.";
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = pkgs.stdenv.hostPlatform.system == "aarch64-linux";
        message = "The Zhiyu BSP requires an aarch64-linux target.";
      }
      {
        assertion = kernel ? modules;
        message = "The Zhiyu initramfs requires a modular kernel.";
      }
    ];

    system.replaceDependencies.replacements = lib.optional cfg.camera.enable {
      oldDependency = camera.upstream;
      newDependency = cameraReplacement;
    };
    boot.kernelPackages = lib.mkDefault (pkgs.linuxPackagesFor p.kernel);
    boot.kernelModules = [ "fastrpc" ] ++ lib.optional cfg.sensors.enable "uinput";
    boot.initrd.enable = false;
    boot.loader.grub.enable = lib.mkDefault false;
    boot.loader.systemd-boot.enable = lib.mkDefault false;
    boot.loader.external = {
      enable = true;
      installHook =
        if cfg.flashOnSwitch then "${p.flasher}/bin/zhiyu-install" else "${pkgs.coreutils}/bin/true";
    };

    hardware.firmware = [ p.firmware ];
    hardware.graphics.enable = lib.mkDefault true;
    hardware.graphics.extraPackages = lib.optional cfg.videoAcceleration p.qcom-va-driver;
    services.udev.packages = lib.mkAfter [ p.udev-rules ];
    boot.extraModprobeConfig = builtins.readFile ../configs/modprobe.d/99-zhiyu-no-trace.conf;

    environment.systemPackages = [
      p.flasher
      pkgs.qbootctl
    ]
    ++ lib.optional cfg.camera.enable camera.upstream;
    environment.etc."machine-info".text = "CHASSIS=tablet\n";
    environment.etc."alsa/ucm2".source = ucm;
    environment.sessionVariables.ALSA_CONFIG_UCM2 = ucm;
    systemd.user.services.wireplumber = lib.mkIf (
      config.services.pipewire.enable && config.services.pipewire.wireplumber.enable
    ) { environment.ALSA_CONFIG_UCM2 = ucm; };

    users.groups.fastrpc = { };
    users.users.fastrpc = {
      isSystemUser = true;
      group = "fastrpc";
      home = sensorRoot;
    };

    systemd.tmpfiles.rules = [
      "d ${sensorRoot} 0755 root root - -"
      "d ${sensorRoot}/sensors 0755 root root - -"
      "L+ ${sensorRoot}/sensors/config - - - - ${p.sns}/share/qcom/sensors/config"
      "L+ ${sensorRoot}/sensors/sns_reg.conf - - - - ${p.sns}/share/qcom/sensors/sns_reg.conf"
      "d ${sensorRoot}/sensors/registry 0755 fastrpc fastrpc - -"
    ];
    systemd.services.hexagonrpcd-adsp-rootpd = adsp "";
    systemd.services.hexagonrpcd-adsp-sensorspd = lib.mkIf cfg.sensors.enable (adsp "-s");
    services.dbus.packages = lib.optional cfg.sensors.enable p.sensord;
    hardware.sensor.iio.enable = lib.mkIf cfg.sensors.enable (lib.mkForce false);
    systemd.services.zhiyu-sensord = lib.mkIf cfg.sensors.enable {
      wantedBy = [ "multi-user.target" ];
      after = [ "hexagonrpcd-adsp-sensorspd.service" ];
      wants = [ "hexagonrpcd-adsp-sensorspd.service" ];
      serviceConfig = {
        Type = "notify";
        NotifyAccess = "all";
        TimeoutStartSec = "30s";
        ExecStart = "${p.sensord}/bin/zhiyu-sensord";
        ExecStartPost = "-${pkgs.systemd}/bin/systemctl try-restart --no-block upower.service";
        Restart = "always";
        RestartSec = 2;
      };
    };

    # The links are part of the generation closure and survive a rollback.
    environment.etc."zhiyu/boot-images".source = images.packages.zhiyu-images;
    environment.etc."zhiyu/boot-id".source = id;
    system.build = {
      zhiyuCamera = lib.mkIf cfg.camera.enable camera;
      zhiyuPipewire = pkgs.pipewire;
      zhiyuImages = images.packages.zhiyu-images;
      zhiyuInitramfs = initramfs;
      zhiyuFirmware = p.firmware;
    };
  };
}
