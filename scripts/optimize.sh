#!/system/bin/sh
# Atria Monitor v3.2.97 - 本地优化执行器
# 用法:
#   optimize.sh              一键优化: 清理大内存非保护进程 + 释放页缓存
#   optimize.sh exec '动作'  执行单条白名单动作: kill <pid> / am force-stop <包名> / drop_caches
# 输出 JSON 结果
#
# v3.1.9 修复 (相对 v3.1.8):
#   1) 保护检查从 comm(15字符截断) 改为 cmdline 完整包名 + comm 双重匹配,
#      修复 "com.android.systemui 被截断为 ndroid.systemui 后 保护名单永不命中" 导致误杀 SystemUI
#   2) 新增内核线程保护 (PID < 100 或 /proc/<pid>/cmdline 为空 -> 跳过, v3.1.8 仅靠 comm 名单)
#   3) 新增前台 App 保护 (dumpsys 判定, 避免杀掉用户正在使用的应用)
#   4) PID 校验改为严格 ^[0-9]+$ (v3.1.8 的 [ "$PID" -gt 0 ] 接受 0777/ 5 等, mksh 八进制解析危险)
#   5) kill 结果判定加入僵尸进程 state Z 识别 (v3.1.8 把已回收/wait 中的进程误报为 "未生效")
#   6) 一键优化改为按 RSS 降序 (v3.1.8 按字典序 head -200, 漏掉高 PID 大进程)
#   7) KILLED 计数只在 kill 真正成功时自增 (v3.1.8 失败被 || continue 吞掉但计数已 +1)
#   8) drop_caches 结果按写入是否成功判定 (v3.1.8 无视失败恒报 ok)
# v3.1.10 修复:
#   1) 一键优化新增宿主 App 白名单 (sukisu/kernelsu/magisk/apatch 等), 修复"优化即闪退" -
#      面板正运行在宿主管理器内, 宿主 RSS 常年 300-600MB 超过杀伤阈值且无保护
#   2) do_optimize 补上前台 App 保护 (此前仅 do_exec 有, 两条路径保护不一致)

# 保护进程白名单 (绝不 kill) - comm 短名
PROTECTED="system_server surfaceflinger zygote zygote64 adbd logd servicemanager vold netd lmkd healthd installd gatekeeperd keystore sensorservice audioserver mediaserver drmserver"
# 保护包名 (cmdline 完整匹配) - v3.1.9: kill 路径也使用此名单
# v3.2.92: 补 AI 助手与输入法 — 前端 KILL_GUARD 对齐, 防止 AI 诊断杀掉对话宿主/输入法
PKG_PROTECTED="com.android.systemui com.android.phone com.android.settings com.android.launcher3 com.android.inputmethod com.niki914.zafiro com.ai.assistance.operit com.iflytek.inputmethod"
# v3.2.34: 精确包名白名单 (完整匹配, 不含子串误伤)
# 面板宿主 / root 管理器 / 常驻服务, 任何 kill / am force-stop / autostart 动作都跳过
PKG_WHITELIST="io.github.a13e300.ksuwebui com.sukisu.ultra com.niki914.zafiro com.topjohnwu.magisk io.github.huskydg.magisk io.github.vvb2060.magisk rikka.magisk me.bmax.apatch com.tsng.hidemyapplist"
# v3.2.34: 用户自定义白名单 - 编辑 /data/adb/atria_whitelist.conf 即可追加包名
# 每行一个包名, # 开头为注释; 文件在 /data/adb 下, 模块更新不影响
WL_FILE="/data/adb/atria_whitelist.conf"
# v3.2.35: 挂载命名空间修正 - KernelSU/APatch root shell 的 /data/data 被 mount ns 隔离
# (实测: root shell 下 /data/data 仅 2 个目录可见, 经 init 命名空间后可见全部 444 个应用)
# 扫描/清理应用缓存必须经 init 命名空间; nsenter 不可用时自动降级为直接执行
command -v nsenter >/dev/null 2>&1 && NSH="nsenter -t 1 -m --" || NSH=""
if [ -r "$WL_FILE" ]; then
  USER_WL=$(sed -e 's/#.*//' -e 's/^[ \t]*//' -e 's/[ \t]*$//' "$WL_FILE" 2>/dev/null | grep -v '^$' | tr '\n' ' ')
  [ -n "$USER_WL" ] && PKG_WHITELIST="$PKG_WHITELIST $USER_WL"
fi

# v3.1.9: Android 原生桌面/输入法/动态壁纸等包名后缀 (cmdline 包含即保护)
# v3.2.34: 缓存清理额外保护 (清缓存会让输入法/桌面短暂重载, 体验差但无数据风险)
PKG_CACHE_RISK="inputmethod launcher systemui wallpaper ime"

json_esc() {
  # v3.1.9: 剔除控制字符, 保留可打印字符与 UTF-8 中文 (POSIX 类取反写作 [[:cntrl:]] 的补集)
  printf '%s' "$1" | tr -d '\000-\037' | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g'
}

pid_name() { cat /proc/$1/comm 2>/dev/null; }
pid_rss() { awk '/VmRSS/{print int($2/1024)}' /proc/$1/status 2>/dev/null; }
# v3.1.9: 完整包名, 不受 15 字符 comm 截断影响
pid_cmdline() { tr '\0' ' ' < /proc/$1/cmdline 2>/dev/null | sed 's/ *$//'; }
# v3.1.9: 僵尸进程判定
pid_state() { awk '{print $3}' /proc/$1/stat 2>/dev/null; }

# v3.1.9: 是否为内核线程 / PID 低于安全下限 (init/kthreadd 等永久保护)
is_kernel_or_low_pid() {
  case "$1" in ''|*[!0-9]*) return 0;; esac
  # PID 1 (init) / 2 (kthreadd) 与低 PID 永远保护
  case "$1" in 1|2) return 0;; esac
  [ "$1" -lt 100 ] && return 0
  CMD=$(pid_cmdline "$1")
  [ -z "$CMD" ] && return 0
  return 1
}

# v3.2.34: 精确包名白名单匹配 (PKG / cmdline 去掉 :suffix 后完整匹配)
# 同时兼容 cmdline 形如 "io.github.a13e300.ksuwebui:root:0"
is_pkg_whitelisted() {
  case " $PKG_WHITELIST " in *" $1 "*) return 0 ;; esac
  return 1
}

# v3.1.9: 前台 App 包名 (只采集一次)
FOREGROUND_PKG=''
detect_foreground() {
  if [ -z "$FOREGROUND_PKG" ]; then
    FOREGROUND_PKG=$(dumpsys activity activities 2>/dev/null | grep -E 'mResumedActivity|topResumedActivity' | head -1 | sed 's/.*u0 \([^ ]*\)\/.*/\1/' | sed 's/.* \([a-zA-Z0-9._]*\)\/.*/\1/')
    [ -z "$FOREGROUND_PKG" ] && FOREGROUND_PKG="unknown"
  fi
  printf '%s' "$FOREGROUND_PKG"
}

is_protected() {
  # 1) comm 短名匹配
  case " $PROTECTED " in *" $1 "*) return 0 ;; esac
  case "$1" in collect_loop.sh|collect.sh|optimize.sh|sh|busybox|magisk|su|logcat) return 0 ;; esac
  # v3.1.9: comm 后缀兜底 (应对截断, 如 ndroid.systemui)
  case "$1" in *systemui*|*launcher*|*inputmethod*|*zygote*) return 0 ;; esac
  return 1
}

# v3.1.9: 包名级保护 (参数: PID)
is_pkg_protected() {
  CMD=$(pid_cmdline "$1")
  [ -z "$CMD" ] && return 0    # 无 cmdline = 内核线程或已死, 保护
  case " $PKG_PROTECTED " in *" $CMD "*) return 0 ;; esac
  case "$CMD" in
    *.launcher*|*.inputmethod*|*.systemui|com.android.systemui|*.wallpaper*) return 0 ;;
  esac
  # v3.2.34: Zafiro AI 助手 (单条 kill 路径也保护)
  case "$CMD" in *zafiro*) return 0 ;; esac
  # v3.1.10: 宿主管理器白名单 (面板正运行其中, 杀掉即闪退)
  case "$CMD" in
    *sukisu*|*kernelsu*|*magisk*|*ricekernel*|*apatch*) return 0 ;;
  esac
  # v3.2.34: KsuWebUI 面板宿主 (io.github.a13e300.ksuwebui, 含 :root 子进程)
  # 原匹配 *sukisu*/*kernelsu* 均不命中 ksuwebui, AI 自动优化杀宿主导致面板闪退
  case "$CMD" in *ksuwebui*|*:webui*) return 0 ;; esac
  # v3.2.34: 精确包名白名单 (cmdline 可能带 :process 后缀, 取首段匹配)
  case "$CMD" in *:*) WPKG="${CMD%%:*}" ;; *) WPKG="$CMD" ;; esac
  is_pkg_whitelisted "$WPKG" && return 0
  # v3.1.9: 前台 App 保护
  FG=$(detect_foreground)
  case " $FG " in *" $CMD "*) return 0 ;; esac
  return 1
}

mem_percent() {
  T=$(awk '/MemTotal/{print int($2/1024)}' /proc/meminfo 2>/dev/null)
  A=$(awk '/MemAvailable/{print int($2/1024)}' /proc/meminfo 2>/dev/null)
  case "$T" in ''|*[!0-9]*) T=0;; esac
  case "$A" in ''|*[!0-9]*) A=0;; esac
  [ "$T" -gt 0 ] 2>/dev/null || T=1
  echo $(( (T - A) * 100 / T ))
}

RES=""
add_res() {
  RES="$RES{\"action\":\"$(json_esc "$1")\",\"status\":\"$2\",\"msg\":\"$(json_esc "$3")\"},"
}

# v3.1.9: kill 前的统一保护闸门 (comm + 包名 + 内核线程 + 前台)
# 返回 0=允许 kill, 1=已拒绝(已写入 add_res 结果)
kill_guard() {
  PID="$1"
  case "$PID" in ''|*[!0-9]*) return 1 ;; esac      # 严格十进制
  [ -d "/proc/$PID" ] || return 1
  NAME=$(pid_name "$PID")
  if is_kernel_or_low_pid "$PID"; then
    add_res "kill $PID" skip "跳过内核/低PID进程 ${NAME:-$PID}"
    return 1
  fi
  [ -z "$NAME" ] && return 1
  if is_protected "$NAME"; then add_res "kill $PID" skip "跳过保护进程 $NAME"; return 1; fi
  if is_pkg_protected "$PID"; then
    CMD=$(pid_cmdline "$PID")
    add_res "kill $PID" skip "跳过系统/前台应用 ${CMD:-$NAME}"
    return 1
  fi
  return 0
}

# ---- 单条白名单动作执行 (供 AI actions / 面板按钮调用) ----
do_exec() {
  ACT="$1"
  case "$ACT" in
    drop_caches)
      if echo 3 > /proc/sys/vm/drop_caches 2>/dev/null; then add_res "$ACT" ok "已释放页缓存"
      else add_res "$ACT" fail "drop_caches 失败 (权限不足)"; fi
      ;;
    kill\ *)
      PID=$(echo "$ACT" | awk '{print $2}')
      # v3.1.9: 严格十进制校验, 拒绝 0777 / +5 / 空白变体
      case "$PID" in ''|*[!0-9]*) add_res "$ACT" fail "无效 PID"; return ;; esac
      [ -d "/proc/$PID" ] || { add_res "$ACT" fail "PID $PID 不存在"; return; }
      kill_guard "$PID" || return
      NAME=$(pid_name "$PID")
      kill "$PID" 2>/dev/null || { add_res "$ACT" fail "kill $PID ($NAME) 失败 (权限不足或已退出)"; return; }
      # v3.2.34: 1s -> 0.3s (足够让多数进程退出, 减少 UI 等待)
      sleep 0.3 2>/dev/null || sleep 1
      # v3.1.9: 僵尸进程 (state Z) 视为已杀死, 正在 wait
      if [ -d "/proc/$PID" ]; then
        ST=$(pid_state "$PID")
        if [ "$ST" = "Z" ]; then add_res "$ACT" ok "已结束 $NAME (PID $PID, 僵尸待收)"
        else add_res "$ACT" fail "kill $PID ($NAME) 未生效"; return; fi
      else
        add_res "$ACT" ok "已结束 $NAME (PID $PID)"
      fi
      ;;
    am\ force-stop\ *)
      PKG=$(echo "$ACT" | awk '{print $3}')
      [ -n "$PKG" ] || { add_res "$ACT" fail "缺少包名"; return; }
      case " $PKG_PROTECTED " in *"$PKG "*) add_res "$ACT" skip "跳过系统应用 $PKG"; return ;; esac
      # v3.2.34: 宿主/面板保护 (原仅查 5 个系统包, AI 自动优化会 force-stop 面板宿主自身 -> 闪退)
      case "$PKG" in
        *ksuwebui*|*sukisu*|*kernelsu*|*magisk*|*apatch*|*zafiro*) add_res "$ACT" skip "跳过宿主/面板应用 $PKG"; return ;;
      esac
      # v3.2.34: 精确包名白名单
      if is_pkg_whitelisted "$PKG"; then add_res "$ACT" skip "跳过白名单应用 $PKG"; return; fi
      # 前台应用保护
      FG=$(detect_foreground)
      case "$FG" in *"$PKG"*) add_res "$ACT" skip "跳过前台应用 $PKG"; return ;; esac
      if am force-stop "$PKG" 2>/dev/null; then add_res "$ACT" ok "已强制停止 $PKG"
      else add_res "$ACT" fail "force-stop $PKG 失败"; fi
      ;;
    # v3.2.34: 清理单个应用缓存 (pm clear-cache 不碰数据)
    clean_cache\ *)
      PKG=$(echo "$ACT" | awk '{print $2}')
      case "$PKG" in ''|*[!a-zA-Z0-9._-]*) add_res "$ACT" fail "无效包名"; return ;; esac
      # v3.2.34: 后缀匹配 (com.android.inputmethod 含 inputmethod 即保护)
      for rk in $PKG_CACHE_RISK; do
        case "$PKG" in *"$rk"*) add_res "$ACT" skip "跳过缓存敏感应用 $PKG"; return ;; esac
      done
      # v3.2.35: 经 init 命名空间检查 (root shell 下 /data/data 被 mount ns 隔离)
      if [ -n "$NSH" ]; then
        $NSH sh -c '[ -d "/data/data/$PKG" ]' 2>/dev/null || { add_res "$ACT" fail "应用 $PKG 不存在"; return; }
      else
        [ -d "/data/data/$PKG" ] || { add_res "$ACT" fail "应用 $PKG 不存在"; return; }
      fi
      if pm clear-cache "$PKG" >/dev/null 2>&1; then
        # v3.2.35: cache 与 code_cache 一并清理, 均经 init 命名空间 (通配符在其内部展开)
        if [ -n "$NSH" ]; then
          $NSH sh -c 'rm -rf "/data/data/$PKG/code_cache"/* "/data/data/$PKG/cache"/*' 2>/dev/null
        else
          rm -rf "/data/data/$PKG/code_cache"/* "/data/data/$PKG/cache"/* 2>/dev/null
        fi
        add_res "$ACT" ok "已清理 $PKG 缓存"
      else
        add_res "$ACT" fail "清理 $PKG 失败 (pm 权限不足)"
      fi
      ;;
    # v3.2.34: 扫描各应用缓存占用 (只读, 不删)
    scan_cache\ *)
      # v3.2.35: du 经 init 命名空间, 且通配符必须在其内部 sh -c 展开
      # (root shell 的 mount ns 里 /data/data 只有极少数目录, glob 在调用侧展开会丢失应用)
      OUT=$(if [ -n "$NSH" ]; then
             $NSH sh -c 'du -sk /data/data/*/code_cache /data/data/*/cache 2>/dev/null'
           else
             du -sk /data/data/*/code_cache /data/data/*/cache 2>/dev/null
           fi | awk '$1 >= 5120 {printf "%s\t%s\n", $1, $2}' | sort -rn | head -20)
      [ -n "$OUT" ] || { add_res "$ACT" ok "无大缓存应用 (阈值 5MB)"; return; }
      MSG=$(printf '%s\n' "$OUT" | awk -F'\t' '{kb=$1; p=$2; sub(/\/data\/data\//,"",p); sub(/\/(code_cache|cache)$/,"",p); printf "%s:%dMB ", p, kb/1024}')
      add_res "$ACT" ok "$MSG"
      ;;
    # v3.2.34: 自启管理 (appops 后台自启动, 可逆)
    autostart\ block\ *)
      PKG=$(echo "$ACT" | awk '{print $3}')
      case "$PKG" in ''|*[!a-zA-Z0-9._-]*) add_res "$ACT" fail "无效包名"; return ;; esac
      case " $PKG_PROTECTED " in *"$PKG "*) add_res "$ACT" skip "跳过系统应用 $PKG"; return ;; esac
      # v3.2.34: 宿主保护
      case "$PKG" in *ksuwebui*|*sukisu*|*kernelsu*|*magisk*|*apatch*|*zafiro*) add_res "$ACT" skip "跳过宿主应用 $PKG"; return ;; esac
      # v3.2.34: 精确包名白名单
      if is_pkg_whitelisted "$PKG"; then add_res "$ACT" skip "跳过白名单应用 $PKG"; return; fi
      if cmd appops set "$PKG" RUN_IN_BACKGROUND ignore >/dev/null 2>&1; then
        add_res "$ACT" ok "已限制 $PKG 后台自启"
      else
        add_res "$ACT" fail "限制 $PKG 失败 (无 appops 权限)"
      fi
      ;;
    autostart\ unblock\ *)
      PKG=$(echo "$ACT" | awk '{print $3}')
      case "$PKG" in ''|*[!a-zA-Z0-9._-]*) add_res "$ACT" fail "无效包名"; return ;; esac
      if cmd appops set "$PKG" RUN_IN_BACKGROUND allow >/dev/null 2>&1; then
        add_res "$ACT" ok "已恢复 $PKG 后台自启"
      else
        add_res "$ACT" fail "恢复 $PKG 失败"
      fi
      ;;
    # v3.2.34: 省电模式 (可逆, 关动画+降亮度+限制后台数据)
    powersave\ on)
      HAS_DUMPSYS=0; command -v dumpsys >/dev/null 2>&1 && HAS_DUMPSYS=1
      ANIM=$(settings get global window_animation_scale 2>/dev/null)
      TRANS=$(settings get global transition_animation_scale 2>/dev/null)
      BRIGHT=$(settings get system screen_brightness 2>/dev/null)
      # 保存当前值以便还原 (锁内存活, 重复开启时只保存第一次)
      if [ -z "$SAVED_ANIM" ]; then SAVED_ANIM=$ANIM; SAVED_TRANS=$TRANS; SAVED_BRIGHT=$BRIGHT; fi
      settings put global window_animation_scale 0 2>/dev/null
      settings put global transition_animation_scale 0 2>/dev/null
      if settings put global restrict_background_data 1 2>/dev/null; then
        add_res "$ACT" ok "已开启省电模式 (动画关, 后台数据受限)"
      else
        add_res "$ACT" ok "已开启省电模式 (动画关)"
      fi
      ;;
    powersave\ off)
      settings put global window_animation_scale "${SAVED_ANIM:-1}" 2>/dev/null
      settings put global transition_animation_scale "${SAVED_TRANS:-1}" 2>/dev/null
      settings put global restrict_background_data 0 2>/dev/null
      add_res "$ACT" ok "已关闭省电模式, 恢复动画 ${SAVED_ANIM:-1}x"
      ;;
    # v3.2.34: 性能模式 (governor 切换, 只允许已知的可写路径)
    perf\ performance|perf\ powersave|perf\ schedutil|perf\ interactive)
      GOV=$(echo "$ACT" | awk '{print $2}')
      FOUND=0
      for cpu in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do
        [ -w "$cpu" ] || continue
        if echo "$GOV" > "$cpu" 2>/dev/null; then FOUND=1; else FOUND=2; break; fi
      done
      case "$FOUND" in
        1) add_res "$ACT" ok "已切换调度器为 $GOV ($(ls /sys/devices/system/cpu/ 2>/dev/null | grep -c 'cpu[0-9]') 核)" ;;   # shellcheck disable=SC2010
        2) add_res "$ACT" fail "写入失败, 调度器未全部切换"
           for cpu in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do echo "$OLD_GOV" > "$cpu" 2>/dev/null; done ;;
        0) add_res "$ACT" fail "无可用调速器路径 (内核不支持)" ;;
      esac
      ;;
    # v3.2.34: vm 参数调校 (可逆)
    vm\ swappiness\ *)
      VAL=$(echo "$ACT" | awk '{print $3}')
      case "$VAL" in ''|*[!0-9]*) add_res "$ACT" fail "无效值"; return ;; esac
      [ "$VAL" -ge 0 ] && [ "$VAL" -le 200 ] || { add_res "$ACT" fail "值需在 0-200"; return; }
      if echo "$VAL" > /proc/sys/vm/swappiness 2>/dev/null; then add_res "$ACT" ok "swappiness=$VAL"
      else add_res "$ACT" fail "写入失败 (非 root?)"; fi
      ;;
    vm\ restore)
      echo "${SAVED_SWAPP:-60}" > /proc/sys/vm/swappiness 2>/dev/null
      add_res "$ACT" ok "已恢复默认 swappiness"
      ;;
    # v3.2.92: 内存碎片整理 (与 drop_caches 互补: drop 释放页缓存, compact 整理碎片)
    # 触发内核 compact_memory, 内存碎片化但 drop_caches 收益不明显时使用
    vm\ compact)
      if echo 1 > /proc/sys/vm/compact_memory 2>/dev/null; then
        add_res "$ACT" ok "已触发内存碎片整理"
      else
        add_res "$ACT" fail "compact 失败 (权限不足或内核不支持)"
      fi
      ;;
    # v3.2.92: GPU 频率上限锁档 (Adreno 设备 max_pwrlevel, 索引 0=最高档)
    # 用途: 游戏发热时锁中低档, 直接掐住热源; max_pwrlevel 0 = 恢复最高档
    # 索引对应 available_frequencies: 0=903M 1=834M 2=770M 3=720M 4=680M 5=578M 6=500M 7=422M 8=366M 9=231M
    gpu\ cap\ *)
      LVL=$(echo "$ACT" | awk '{print $3}')
      case "$LVL" in ''|*[!0-9]*) add_res "$ACT" fail "无效档位 (需 0-9 数字)"; return ;; esac
      if [ "$LVL" -lt 0 ] || [ "$LVL" -gt 9 ]; then add_res "$ACT" fail "档位需在 0-9 之间"; return; fi
      PWR=/sys/class/kgsl/kgsl-3d0/max_pwrlevel
      if [ ! -w "$PWR" ]; then add_res "$ACT" fail "GPU 调频节点不可写 (非 Adreno 设备?)"; return; fi
      # 保存当前值以便恢复
      [ -z "$SAVED_GPU_LVL" ] && SAVED_GPU_LVL=$(cat "$PWR" 2>/dev/null)
      if echo "$LVL" > "$PWR" 2>/dev/null; then
        FREQ=$(cat /sys/class/kgsl/kgsl-3d0/freq_table_mhz 2>/dev/null | awk -v i="$LVL" '{print $(i+1)}')
        case "$LVL" in
          0) add_res "$ACT" ok "GPU 已解除限频 (恢复最高档 903MHz)" ;;
          *) add_res "$ACT" ok "GPU 频率上限已锁第 $LVL 档 (${FREQ}MHz)" ;;
        esac
      else
        add_res "$ACT" fail "GPU 锁频写入失败"
      fi
      ;;
    # v3.2.92: GPU 解除限频 (恢复最高档)
    gpu\ restore)
      PWR=/sys/class/kgsl/kgsl-3d0/max_pwrlevel
      if [ -w "$PWR" ] && echo 0 > "$PWR" 2>/dev/null; then
        SAVED_GPU_LVL=""
        add_res "$ACT" ok "GPU 已解除限频"
      else
        add_res "$ACT" fail "GPU 解锁失败 (节点不可写)"
      fi
      ;;
    # v3.2.92: 冻结应用 (pm disable-user, 比 force-stop 彻底: 不自启不占资源)
    # 可逆: freeze <包名>; 配套 unfreeze <包名>
    freeze\ *)
      PKG=$(echo "$ACT" | awk '{print $2}')
      case "$PKG" in ''|*[!a-zA-Z0-9._-]*) add_res "$ACT" fail "无效包名"; return ;; esac
      # v3.2.92: 冻结保护 — 系统应用/宿主/输入法/启动器一律拒绝, 冻错会开不了机
      case " $PKG_PROTECTED " in *"$PKG "*) add_res "$ACT" skip "跳过系统应用 $PKG (冻结危险)"; return ;; esac
      case "$PKG" in
        *ksuwebui*|*sukisu*|*kernelsu*|*magisk*|*apatch*|*zafiro*) add_res "$ACT" skip "跳过宿主应用 $PKG"; return ;;
        *launcher*|*inputmethod*|*systemui*) add_res "$ACT" skip "跳过关键应用 $PKG (冻结影响系统)"; return ;;
      esac
      if is_pkg_whitelisted "$PKG"; then add_res "$ACT" skip "跳过白名单应用 $PKG"; return; fi
      if pm disable-user "$PKG" >/dev/null 2>&1; then
        add_res "$ACT" ok "已冻结 $PKG (后台不再运行)"
      else
        add_res "$ACT" fail "冻结 $PKG 失败"
      fi
      ;;
    # v3.2.92: 解除冻结
    unfreeze\ *)
      PKG=$(echo "$ACT" | awk '{print $2}')
      case "$PKG" in ''|*[!a-zA-Z0-9._-]*) add_res "$ACT" fail "无效包名"; return ;; esac
      if pm enable "$PKG" >/dev/null 2>&1; then
        add_res "$ACT" ok "已解除冻结 $PKG"
      else
        add_res "$ACT" fail "解冻 $PKG 失败"
      fi
      ;;
    # v3.2.34: 模块启用/禁用 (touch/rm disable 文件, 立即生效)
    module\ enable\ *)
      MID=$(echo "$ACT" | awk '{print $3}')
      case "$MID" in ''|*[!a-zA-Z0-9._-]*) add_res "$ACT" fail "无效模块 id"; return ;; esac
      MDIR=""
      for d in "$MROOT/$MID" "$MROOT_UPDATE/$MID"; do
        [ -d "$d" ] && { MDIR="$d"; break; }
      done
      [ -n "$MDIR" ] || { add_res "$ACT" fail "模块 $MID 不存在"; return; }
      if rm -f "$MDIR/disable" 2>/dev/null; then add_res "$ACT" ok "模块 $MID 已启用"
      else add_res "$ACT" fail "启用 $MID 失败 (权限不足)"; fi
      ;;
    module\ disable\ *)
      MID=$(echo "$ACT" | awk '{print $3}')
      case "$MID" in ''|*[!a-zA-Z0-9._-]*) add_res "$ACT" fail "无效模块 id"; return ;; esac
      MDIR=""
      for d in "$MROOT/$MID" "$MROOT_UPDATE/$MID"; do
        [ -d "$d" ] && { MDIR="$d"; break; }
      done
      [ -n "$MDIR" ] || { add_res "$ACT" fail "模块 $MID 不存在"; return; }
      if touch "$MDIR/disable" 2>/dev/null; then add_res "$ACT" ok "模块 $MID 已禁用"
      else add_res "$ACT" fail "禁用 $MID 失败 (权限不足)"; fi
      ;;
    *)
      add_res "$ACT" reject "非白名单动作, 拒绝执行"
      ;;
  esac
}

# ---- 一键优化 ----
# v3.1.10: 宿主 App 白名单 - 一键优化杀掉正在显示面板的 KernelSU/SukiSU/Magisk 管理器会导致面板闪退
HOST_PROTECTED="sukisu kernelsu magisk ksu ricekernel apatch magisk_delta zafiro"
# v3.2.34: 保护常驻 AI 助手 Zafiro (com.niki914.zafiro 及 :python 子进程, RSS 常年 200-400MB)
# - 一键优化按 RSS 排序杀进程时, 未加保护会把 AI 助手当内存大户杀掉 (面板功能的宿主之一)

do_optimize() {
  BEFORE=$(mem_percent)
  # v3.1.9: 按 RSS 降序遍历 (v3.1.8 按字典序 head -200, 漏掉高 PID 大进程)
  # 整个遍历与计数都在 awk 内完成, 逐行输出 JSON 记录, 规避管道子 shell 丢失变量
  # v3.2.34: 结果文件 PID 唯一化, 防止两个一键优化并发互相覆盖
  RESFILE=/data/local/tmp/atria_opt_res_$$.txt
  : > "$RESFILE" 2>/dev/null
  # v3.1.10: 前台 App (dumpsys) 与宿主白名单一并传入 awk, 一键优化与单条 exec 保护一致
  FGP=$(detect_foreground 2>/dev/null)
  ps -A -o pid,rss,comm 2>/dev/null | awk -v resfile="$RESFILE" -v prot="$PROTECTED $PKG_PROTECTED" -v host="$HOST_PROTECTED" -v wl="$PKG_WHITELIST" -v fg="$FGP" '
  BEGIN { split(prot, P, " "); np = 0; for (k in P) { np++; KEYS[np] = P[k] }; split(host, H, " "); nh = 0; for (k in H) { nh++; HK[nh] = H[k] }; split(wl, W, " "); nw = 0; for (k in W) { nw++; WL[nw] = W[k] } }
  $1 ~ /^[0-9]+$/ && $2 ~ /^[0-9]+$/ && $2 >= 302920 {
    pid = $1 + 0; rss = int($2 / 1024)
    cmdfile = "/proc/" pid "/cmdline"
    cmd = ""
    while ((getline ch < cmdfile) > 0) cmd = cmd (cmd == "" ? "" : " ") ch
    close(cmdfile)
    commfile = "/proc/" pid "/comm"
    getline comm < commfile; close(commfile)
    gsub(/[^[:print:]]/, "", comm)
    # 无 cmdline 的内核线程 / 低 PID 一律保护
    if (cmd == "" || pid < 100) { printf "%s", "{\"action\":\"kill " pid "\",\"status\":\"skip\",\"msg\":\"跳过内核/低PID进程 " comm "\"}," >> resfile; next }
    lcmd = tolower(cmd); lcomm = tolower(comm)
    skip = 0; reason = ""
    for (k = 1; k <= np; k++) {
      if (index(lcmd, tolower(KEYS[k])) > 0) { skip = 1; reason = "保护进程"; break }
    }
    # v3.1.10: 宿主管理器 (面板正在其中运行, 杀掉即闪退)
    if (!skip) for (k = 1; k <= nh; k++) {
      if (index(lcmd, HK[k]) > 0) { skip = 1; reason = "宿主面板"; break }
    }
    # v3.2.34: 精确包名白名单 (cmdline 去掉 :后缀 完整匹配)
    if (!skip) {
      wp = lcmd; wi = index(wp, ":"); if (wi > 0) wp = substr(wp, 1, wi - 1)
      for (k = 1; k <= nw; k++) { if (wp == WL[k]) { skip = 1; reason = "白名单"; break } }
    }
    if (!skip && (lcomm ~ /systemui/ || lcomm ~ /launcher/ || lcomm ~ /inputmethod/ || lcomm ~ /zygote/)) { skip = 1; reason = "系统进程" }
    # v3.1.9: 前台 App 保护 (与 do_exec 的 is_pkg_protected 一致)
    if (!skip && fg != "" && fg != "unknown" && index(lcmd, tolower(fg)) > 0) { skip = 1; reason = "前台应用" }
    if (skip) { printf "%s", "{\"action\":\"kill " pid "\",\"status\":\"skip\",\"msg\":\"跳过" reason " " comm "\"}," >> resfile; next }
    if (system("kill " pid) == 0) {
      printf "%s", "{\"action\":\"kill " pid "\",\"status\":\"ok\",\"msg\":\"一键优化: 结束 " comm " (" rss "MB)\"}," >> resfile
      killed++
    } else {
      printf "%s", "{\"action\":\"kill " pid "\",\"status\":\"fail\",\"msg\":\"kill " comm " 失败\"}," >> resfile
    }
  }
  END { print killed > "/data/local/tmp/atria_opt_killed_'$$'.txt" }
  '
  KILLED=$(cat "/data/local/tmp/atria_opt_killed_$$.txt" 2>/dev/null)
  case "$KILLED" in ''|*[!0-9]*) KILLED=0;; esac
  rm -f "/data/local/tmp/atria_opt_killed_$$.txt" 2>/dev/null
  RES=$(cat "$RESFILE" 2>/dev/null)
  SKIPPED=$(printf '%s' "$RES" | grep -o '"status":"skip"' | wc -l)
  case "$SKIPPED" in ''|*[!0-9]*) SKIPPED=0;; esac
  rm -f "$RESFILE" 2>/dev/null
  if echo 3 > /proc/sys/vm/drop_caches 2>/dev/null; then
    add_res "drop_caches" ok "一键优化: 释放页缓存"
  else
    add_res "drop_caches" fail "一键优化: drop_caches 失败"
  fi
  # v3.2.34: 1s -> 0.3s (内存采样无需等满 1 秒)
  sleep 0.3 2>/dev/null || sleep 1
  AFTER=$(mem_percent)
  printf '{"mode":"optimize","before":%s,"after":%s,"freed_pct":%s,"killed":%s,"skipped_protected":%s,"results":[%s]}\n' \
    "$BEFORE" "$AFTER" "$((BEFORE - AFTER))" "$KILLED" "$SKIPPED" "${RES%,}"
}

# v3.2.34: 模块路径探测 (APatch 用 /data/adb/ap/modules)
MROOT=/data/adb/modules
[ -d "$MROOT" ] || MROOT=/data/adb/ap/modules
MROOT_UPDATE=/data/adb/modules_update
[ -d "$MROOT_UPDATE" ] || MROOT_UPDATE=/data/adb/ap/modules_update

# ---- 入口 ----
case "$1" in
  exec)
    if [ -z "$2" ]; then
      printf '{"mode":"exec","error":"缺少动作参数"}\n'
      exit 1
    fi
    do_exec "$2"
    printf '{"mode":"exec","results":[%s]}\n' "${RES%,}"
    ;;
  optimize|"")
    do_optimize
    ;;
  *)
    # v3.1.9: 未知参数经转义, 不再原样拼接破坏 JSON
    printf '{"mode":"error","error":"未知参数: %s"}\n' "$(json_esc "$1")"
    exit 1
    ;;
esac