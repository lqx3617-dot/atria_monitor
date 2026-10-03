#!/system/bin/sh
# Atria Monitor v3.4.6 - 安装脚本
MODDIR=${0%/*}

set_perm_recursive "$MODDIR" 0 0 0755 0644
set_perm "$MODDIR/scripts/collect.sh"      0 0 0755
set_perm "$MODDIR/scripts/collect_loop.sh" 0 0 0755
set_perm "$MODDIR/scripts/optimize.sh"     0 0 0755
set_perm "$MODDIR/service.sh"              0 0 0755
set_perm "$MODDIR/uninstall.sh"            0 0 0755

# v3.2.36: 确认 C 图标提取器可执行 (native/icon_extract_c_arm64)
IBIN="$MODPATH/native/icon_extract_c_arm64"
if [ -f "$IBIN" ]; then
  set_perm "$IBIN" 0 0 0755
fi

# v3.2.34: 确认 C 采集器可执行 (native/collect_c_arm64)
CBIN="$MODPATH/native/collect_c_arm64"
if [ -f "$CBIN" ]; then
  set_perm "$CBIN" 0 0 0755
fi

# 预置空状态对象, 避免面板首次刷新前读取失败
printf '{}' > /data/local/tmp/atria_status.json 2>/dev/null
set_perm /data/local/tmp/atria_status.json 0 0 0644 2>/dev/null

# v3.2.34: 用户自定义包名白名单 (已存在则不覆盖, 保留用户配置)
WL_FILE=/data/adb/atria_whitelist.conf
if [ ! -f "$WL_FILE" ]; then
  printf '# Atria Monitor 自定义保护白名单\n' > "$WL_FILE" 2>/dev/null
  printf '# 每行一个包名, # 开头为注释. 重启或模块更新后依然生效.\n' >> "$WL_FILE" 2>/dev/null
  printf '# 示例 (取消注释即生效):\n' >> "$WL_FILE" 2>/dev/null
  printf '#com.tencent.mm\n' >> "$WL_FILE" 2>/dev/null
  printf '#com.miui.player\n' >> "$WL_FILE" 2>/dev/null
  set_perm "$WL_FILE" 0 0 0644 2>/dev/null
fi

# v3.2.36: 白名单应用图标预提取
# 图标目录放 /data/local/tmp: /data/adb 为 drwx------ root root, KsuWebUI 面板以
# App UID (u0_a311) 渲染 WebView, 无权访问 /data/adb, 故图标必须放世界可读路径,
# 与 atriA_status.json 同一已验证可读模式 (root:root 0644, shell_data_file).
ICONDIR=/data/local/tmp/atria_icons
WL_FILE=/data/adb/atria_whitelist.conf
mkdir -m 0755 -p "$ICONDIR" 2>/dev/null
if [ -x "$MODPATH/native/icon_extract_c_arm64" ] && [ -f "$WL_FILE" ]; then
  "$MODPATH/native/icon_extract_c_arm64" --whitelist "$WL_FILE" "$ICONDIR" >/dev/null 2>&1
  chmod 0644 "$ICONDIR"/* 2>/dev/null
fi

ui_print "- Atria Monitor v3.4.6 已安装"
ui_print "- 重启后查看监控面板:"
ui_print "- KernelSU/SukiSU: 管理器中点击本模块"
ui_print "- Magisk/APatch: root 文件管理器打开 webroot/index.html"