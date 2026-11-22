{ base }:
base.overrideAttrs (old: {
  # replaceDependencies rewrites byte strings, but not UTF-16 QStringLiteral
  # store paths. Convert the compiled-in paths to QString at runtime.
  postPatch = (old.postPatch or "") + ''
    substituteInPlace src/auth/Auth.cpp \
      --replace-fail 'QStringLiteral(LIBEXEC_INSTALL_DIR)' 'QString::fromUtf8(LIBEXEC_INSTALL_DIR)'
    substituteInPlace src/common/MainConfigLoader.cpp \
      --replace-fail 'QStringLiteral(SYSTEM_CONFIG_DIR)' 'QString::fromUtf8(SYSTEM_CONFIG_DIR)'
    substituteInPlace src/frontend/settings/plasmaloginsettingsdefaults.cpp \
      --replace-fail 'QStringLiteral(PLASMALOGIN_SYSTEM_CONFIG_FILE)' 'QString::fromUtf8(PLASMALOGIN_SYSTEM_CONFIG_FILE)'
    substituteInPlace src/frontend/settings/plasmaloginsettings.cpp \
      --replace-fail 'QStringLiteral(PLASMALOGIN_SYSTEM_CONFIG_FILE)' 'QString::fromUtf8(PLASMALOGIN_SYSTEM_CONFIG_FILE)' \
      --replace-fail 'QStringLiteral(PLASMALOGIN_SYSTEM_CONFIG_DIR)' 'QString::fromUtf8(PLASMALOGIN_SYSTEM_CONFIG_DIR)'
  '';
})
