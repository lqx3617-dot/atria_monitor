#!/system/bin/sh
# v3.3.1: du/wakelock 注入点修复 (inject_kernel 追加后插入点错位)
# v3.2.100: 耗电来源显示稳定性修复 (空锁不注入, 排除 WindowManager 屏幕锁)
# 独立文件原因: shell 引号嵌套在 patch 脚本里转义层次太多极易出错,
# 独立文件保持裸 shell 形态, 任何读取失败时整个字段不注入, 不影响原 JSON

# ---- wakelock 持有者 (dumpsys power 解析), 息屏掉电根因 ----
# /sys/power/wake_lock 只列内核锁; 用户态锁在 dumpsys power 的 Wake Locks 段
WL_CACHE=''
WL_TICK=0
inject_wl() {
  WL_CACHE=''
  _KWL=$(cat /sys/power/wake_lock 2>/dev/null | tr '\n' ';' 2>/dev/null)
  WL_TICK=$((WL_TICK + 1))
  if [ "$WL_TICK" -ge 5 ]; then
    WL_TICK=0
    # v3.2.100: 排除 WindowManager 屏幕锁 (WindowManager/displayId), 亮屏时永远存在
    # 是正常现象, 混入会掩盖真正的耗电元凶并导致面板恒显示 1 个锁
    _UWL=$(dumpsys power 2>/dev/null | grep -E 'WAKE_LOCK' | grep -v 'WindowManager' | head -4 | while IFS= read -r _L; do
      _TAG=$(printf '%s' "$_L" | awk '{print $1}')
      _ACQ=$(printf '%s' "$_L" | grep -oE 'ACQ=-[0-9]+m[0-9]+s' | head -1)
      _PKG=$(printf '%s' "$_L" | grep -oE 'com\.[a-zA-Z0-9_.]+' | head -1)
      [ -n "$_PKG" ] || _PKG=$(printf '%s' "$_L" | grep -oE 'uid=[0-9]+' | head -1)
      [ -n "$_TAG" ] && printf '%s|%s|%s;' "$_TAG" "$_ACQ" "$_PKG"
    done)
    WL_CACHE="$_UWL"
  fi
  # v3.2.98: _KWL 只允许字母数字 ; _ -, 其余一律视为非法并清空 (防 JSON 注入)
  _BAD=$(printf '%s' "$_KWL" 2>/dev/null | tr -d 'A-Za-z0-9;_-')
  [ -n "$_BAD" ] && _KWL=''
  # v3.2.100: 空或纯分隔符 (; / ;;) 一律视为无锁, 不注入字段
  _KWL=$(printf '%s' "$_KWL" | tr -d ';' | tr -d ' ')
  if [ -n "$_KWL" ]; then
    _KWL=$(printf '%s' "$_KWL" | cut -c1-120)
    _WJ=$(printf '%s' "$_KWL")
  else
    _WJ=''
  fi
  if [ -n "$WL_CACHE" ]; then
    WL_CACHE=$(printf '%s' "$WL_CACHE" | cut -c1-240)
    if [ -n "$_WJ" ]; then
      _WJ="$_WJ|$WL_CACHE"
    else
      _WJ="$WL_CACHE"
    fi
  fi
  if [ -n "$_WJ" ]; then
    case "$DATA" in
      '{'*) DATA=$(printf '%s' "$DATA" | sed "s|}$|,\"wakelock\":\"$_WJ\"}|") ;;
    esac
  fi
}

# ---- 存储空间分析: /data/data top5 + Android/data top5 + 外存 top5 ----
# du 扫描每 ~80s 一次 (DU_TICK>=20, 主循环 ~4s), 字段失败时不注入
# v3.2.98: 嵌套结构 "du":{"data":{...},"appdata":{...},"ext":{...}} (前端按 src 分组)
DU_CACHE=''
DU_TICK=0
inject_du() {
  DU_TICK=$((DU_TICK + 1))
  if [ "$DU_TICK" -ge 20 ]; then
    DU_TICK=0
    DU_CACHE=''
    _DJ=''
    for _SRC in /data/data /storage/emulated/0/Android/data /storage/emulated/0; do
      case "$_SRC" in
        /data/data) _KEY=data ;;
        /storage/emulated/0/Android/data) _KEY=appdata ;;
        *) _KEY=ext ;;
      esac
      _DIRS=$(du -s "$_SRC"/* 2>/dev/null | sort -rn | head -5)
      [ -n "$_DIRS" ] || continue
      printf '%s\n' "$_DIRS" | awk -F'\t' '{
        n = split($2, parts, "/"); base = parts[n]
        gsub(/"/, "", base)
        if (base != "" && $1 + 0 > 10240) printf "\"%s\":%d,", base, $1 + 0
      }' > /tmp/.atria_du_out 2>/dev/null
      _SEG=$(cat /tmp/.atria_du_out 2>/dev/null)
      rm -f /tmp/.atria_du_out 2>/dev/null
      if [ -n "$_SEG" ]; then
        _SEG="${_SEG%,}"
        if [ -n "$_DJ" ]; then _DJ="$_DJ,"; fi
        _DJ="$_DJ\"$_KEY\":{$_SEG}"
      fi
    done
    [ -n "$_DJ" ] && DU_CACHE="$_DJ"
  fi
  if [ -n "$DU_CACHE" ]; then
    case "$DATA" in
      '{'*) DATA=$(printf '%s' "$DATA" | sed "s|}$|,\"du\":{$DU_CACHE}}|") ;;
    esac
  fi
}