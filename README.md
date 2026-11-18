## 联想小新Pad Pro GT 13 Linux方案
### 适配情况
| 子系统 | 状态 | 说明 |
|---|---|---|
| 启动 / 双系统 | ✅ | 共享分区，a/b槽启动，使用fastboot切换槽位 |
| WiFi | ✅ | 千兆网络下测速 |
| UFS | ✅ | - |
| 显示 / 面板 | ✅ | 60/90/120/144Hz刷新率正常，背光可调节 |
| 音频（四扬声器+双麦克风） | ✅ | 扬声器可独立发声 |
| 触控 | ✅ | 触摸、手写笔正常 |
| 摄像头（前摄+后摄） | ✅ | 使用软件isp。部分软件需要libcamerify配合，未适配所有软件 |
| 视频硬件加速 | ✅ | VA-API与V4L2-M2M两种模型，浏览器可硬件解码 |
| 蓝牙 | ✅ | - |
| 电源 / 电池 | ✅ | 测试充电峰值40W |
| 磁吸皮套 | ✅ | 由sensord提供服务 |
| USB | ✅ | 10Gbps测试通过，可在host/device下工作，DP输出已测试2k@165Hz |
| 挂起 / 恢复 | ⚠️ | s2idle正常；deep下偶发自动唤醒 |
| GPU | ⚠️ | 偶发GPU hang,等上游修复 |
| RTC | ⚠️ | 可读写和定时唤醒，但冷启动后日期有偏移 |
| 传感器 | ⚠️ | 用户态实现，未接入IIO子系统。sensord向D-Bus提供环境光和屏幕方向、旋转声道 |
| 手写笔 | ⚠️ | 手写笔可实现基础功能（定位、压感、倾斜、电量）（适配AP501U），二代笔未测试。仅60/120Hz刷新率下可使用 |
| 手电筒 | ⚠️ | 可手动写sysfs打开，未测试用户层软件 |
| 磁吸键盘 | ❌ | 未适配，无法测试 |
| 杜比音效 | ❌ | 无法适配 |
### 食用方法
1. 请先解锁Bootloader  
2. 底包基于ZUXOS 2.0.10.252，请自行提取底包或首先刷入该ROM（或基于该底包的ROM），并同步AB槽
   * 可以使用bootloader刷入的：bluetooth, boot, cpucp, cpucp_dtb, dsp, dtbo, featenabler, init_boot, modem, multiimgqti, pdp, pvmfw, qweslicstore, recovery, shrm, soccp_dcd, soccp_debug, spuservice, uefi, vbmeta, vbmeta_system, vendor_boot
   * 只能使用root或者EDL刷入的：abl, aop, aop_config, devcfg, hyp, imagefv, keymaster, multiimgoem, qupfw, pdp_cdb, tz, uefisecapp, xbl, xbl_config
   * 由于线刷包只会写入A槽，请务必确保这些分区有实际内容，否则将会在切槽后陷入EDL模式！
3. 前往 [Releases](https://github.com/PickaxeHit/linux-zhiyu/releases/tag/packages) 下载最新分区镜像

   公共部分：
   * [vendor_boot.img](https://github.com/PickaxeHit/linux-zhiyu/releases/download/zhiyu-images/vendor_boot.img)
   * [init_boot.img](https://github.com/PickaxeHit/linux-zhiyu/releases/download/zhiyu-images/init_boot.img)

   发行版相关：
   * 不指定主 LSM（默认，如 ArchLinux）：[boot.img](https://github.com/PickaxeHit/linux-zhiyu/releases/download/zhiyu-images/boot.img) + [vbmeta.img](https://github.com/PickaxeHit/linux-zhiyu/releases/download/zhiyu-images/vbmeta.img)
   * 启用 SELinux，RedHat 系（如 Fedora）：[boot-selinux.img](https://github.com/PickaxeHit/linux-zhiyu/releases/download/zhiyu-images/boot-selinux.img) + [vbmeta-selinux.img](https://github.com/PickaxeHit/linux-zhiyu/releases/download/zhiyu-images/vbmeta-selinux.img)
   * 启用 AppArmor，Debian 系（如 Ubuntu）：[boot-apparmor.img](https://github.com/PickaxeHit/linux-zhiyu/releases/download/zhiyu-images/boot-apparmor.img) + [vbmeta-apparmor.img](https://github.com/PickaxeHit/linux-zhiyu/releases/download/zhiyu-images/vbmeta-apparmor.img)
4. 前往[rootfs仓库](https://github.com/PickaxeHit/linux-zhiyu-rootfs-builder)，[fork](https://github.com/PickaxeHit/linux-zhiyu-rootfs-builder/fork)该仓库到自己账号下，并启用Action  
5. 在自己的rootfs仓库下，根据自己的偏好与设置，在Action中触发一次构建  
6. 下载构建好的rootfs，并解压到设备中，内容物为.tar.xz后缀。请自行核对hash  
7. 使用具有root权限的终端，在/data/下创建linux子目录。完整路径为/data/linux/  
8. 将rootfs以root身份解压至/data/linux下，并检查/data/linux/sbin/init是否存在（有可能多一级或少一级，此时需要删除整个linux目录并从第7步开始）。
   * 非SELinux: `tar -xJvf /path/to/rootfs.tar.xz -C /data/linux`
   * 启用SELinux: `tar -xJvf /path/to/rootfs.tar.xz -C /data/linux --numeric-owner --same-owner --same-permissions --xattrs --xattrs-include='security.*'`
9. 刷入第3步下载的四个镜像至未使用的槽位（可使用`adb shell getprop ro.boot.slot_suffix`检查当前槽位）  
10. 重启至该槽位
### 注意事项
1. 请先自行备份所有关键分区并确保自己有救砖条件，在刷入和执行前先自行检查镜像内容
2. 共享分区方案为实验性可能会导致分区出错，不保证android端不出现数据损坏、无法开机等现象。可自行评估风险与可用性
3. linux端具有root权限，具有读写任意分区（以及RPMB区块）的能力，谨防恶意软件与误操作
4. 系统内安装有`qbootctl`，仅用于标记启动成功。在[PR#7](https://github.com/linux-msm/qbootctl/pull/7)或相关PR合并并同步至发行版前，请勿使用`qbootctl -s`切换槽位
5. 若使用过程中出现严重问题请及时反馈
### 参考项目
https://github.com/yzddmr6/xiaomipad-8pro-mainline

https://github.com/KunBuFenZi/progt13-ubuntu
