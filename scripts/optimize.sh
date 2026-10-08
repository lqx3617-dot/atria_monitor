#!/system/bin/sh
# Atria Monitor v3.4.87 - 本地优化执行器
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

# v3.4.22: 媒体播放保护 — 识别正在播放音乐/音频的应用, 一键优化与 AI kill 均跳过
# 数据源: dumpsys media_session
#   1) Sessions Stack 块: package=X + state=3 (PlaybackState.STATE_PLAYING) = 正在播放
#   2) "Audio playback (lastly played comes first)" 段: 最近播放过的应用 (兜底, 播放中必在列表)
# 返回: 播放中包名列表 (空格分隔), 结果缓存避免逐进程 fork dumpsys
MEDIA_PLAYING=''
detect_media_playing() {
  if [ -n "$MEDIA_PLAYING" ]; then printf '%s' "$MEDIA_PLAYING"; return; fi
  local MS PKG INPLAY SECTION
  MS=$(dumpsys media_session 2>/dev/null)
  if [ -z "$MS" ]; then MEDIA_PLAYING='__none__'; printf '%s' "$MEDIA_PLAYING"; return; fi
  INPLAY=''
  # 1) Sessions stack: 同一块内 package=X 且 state=3 (STATE_PLAYING) = 正在播放
  # 块头: "  <pkg>/<act> (userId=" (两空格缩进); 块内含 package= 与 state=
  printf '%s\n' "$MS" | awk '
    /^  [A-Za-z0-9._]+\/[A-Za-z0-9._\/]* ?\(userId=|^  [A-Za-z0-9._]+ \(userId=/ {
      if (pkg != "" && state == "play") print pkg
      pkg = ""; state = ""
    }
    /package=/ { if (match($0, /package=[A-Za-z0-9._-]+/)) pkg = substr($0, RSTART+8, RLENGTH-8) }
    /^    state=[0-9]| state=[0-9]/ {
      if (match($0, /state=[0-9]+/)) { s = substr($0, RSTART+6, RLENGTH-6); if (s == "3") state = "play" }
    }
    END { if (pkg != "" && state == "play") print pkg }
  ' > /tmp/.atria_ms_$$.txt 2>/dev/null
  while IFS= read -r PKG; do
    [ -n "$PKG" ] || continue
    case " $INPLAY " in *" $PKG "*) ;; *) INPLAY="$INPLAY $PKG" ;; esac
  done < /tmp/.atria_ms_$$.txt 2>/dev/null
  rm -f /tmp/.atria_ms_$$.txt 2>/dev/null
  # 2) Audio playback 段兜底 (该段内 packages 视为播放相关, 保守保护)
  SECTION=$(printf '%s\n' "$MS" | sed -n '/Audio playback/,/^Media session config/p' 2>/dev/null)
  printf '%s\n' "$SECTION" | grep -oE 'packages=[A-Za-z0-9._-]+' 2>/dev/null | sed 's/packages=//' > /tmp/.atria_mp_$$.txt 2>/dev/null
  while IFS= read -r PKG; do
    [ -n "$PKG" ] || continue
    case " $INPLAY " in *" $PKG "*) ;; *) INPLAY="$INPLAY $PKG" ;; esac
  done < /tmp/.atria_mp_$$.txt 2>/dev/null
  rm -f /tmp/.atria_mp_$$.txt 2>/dev/null
  MEDIA_PLAYING="${INPLAY# }"
  [ -z "$MEDIA_PLAYING" ] && MEDIA_PLAYING='__none__'
  printf '%s' "$MEDIA_PLAYING"
}

# v3.4.22: 判断包名是否正在播放音频 (供 kill_guard / do_optimize 调用)
is_media_playing() {
  [ -z "$1" ] && return 1
  [ -z "$MEDIA_PLAYING" ] && detect_media_playing >/dev/null 2>&1
  [ "$MEDIA_PLAYING" = "__none__" ] && return 1
  case " $MEDIA_PLAYING " in *" $1 "*) return 0 ;; esac
  return 1
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
  # v3.4.22: 媒体播放保护 — 正在播放音乐/音频的应用不杀 (用户明确要求)
  CMD=$(pid_cmdline "$PID")
  case "$CMD" in
    '') ;;
    *)
      CPKG=$(printf '%s' "$CMD" | awk '{print $1}' | sed 's/.*://')
      if is_media_playing "$CPKG"; then
        add_res "kill $PID" skip "跳过正在播放音频 ${CPKG:-$NAME}"
        return 1
      fi
      ;;
  esac
  return 0
}

# ---- 单条白名单动作执行 (供 AI actions / 面板按钮调用) ----
do_exec() {
  ACT="$1"
  case "$ACT" in
    # v3.4.32: 应急解锁 (锁机木马防护): freeze/uninstall/remove_admin/clear_overlay/lockscreen_clear
    emergency_unblock\ *)
      do_emergency "$ACT"
      ;;
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
      # v3.4.22: 媒体播放保护 — 正在播放音频的应用不得 force-stop
      if is_media_playing "$PKG"; then add_res "$ACT" skip "跳过正在播放音频 $PKG"; return; fi
      if am force-stop "$PKG" 2>/dev/null; then add_res "$ACT" ok "已强制停止 $PKG"
      else add_res "$ACT" fail "force-stop $PKG 失败"; fi
      ;;
    # v3.4.21: 一键清理全部大缓存应用 (>=50MB, 复用单应用清理逻辑与保护名单)
    # 参数: clean_cache_all [阈值MB, 默认50] — 只清理 scan_cache 的大缓存集合, 不全量扫
    clean_cache_all\ *)
      TH=$(echo "$ACT" | awk '{print $2}')
      case "$TH" in ''|*[!0-9]*) TH=50 ;; esac
      [ "$TH" -ge 10 ] && [ "$TH" -le 2048 ] || TH=50
      # v3.2.35: du 经 init 命名空间 (root shell 的 mount ns 里 /data/data 被隔离)
      OUT=$(if [ -n "$NSH" ]; then
             $NSH sh -c 'du -sk /data/data/*/code_cache /data/data/*/cache 2>/dev/null'
           else
             du -sk /data/data/*/code_cache /data/data/*/cache 2>/dev/null
           fi | awk -v TH=$((TH * 1024)) '$1 >= TH {printf "%s\t%s\n", $1, $2}' | sort -rn | head -20)
      if [ -z "$OUT" ]; then add_res "$ACT" ok "无大缓存应用 (阈值 ${TH}MB)"; return; fi
      # v3.4.21: 提取去重包名列表 (while 读管道会子 shell 化丢失计数器, 改 for + 数组)
      PKGLIST=$(echo "$OUT" | awk -F'\t' '{print $2}' | awk -F/ '{print $4}' | sort -u)
      FG=$(detect_foreground 2>/dev/null)
      OK_CNT=0; SKIP_CNT=0; FAIL_CNT=0; SKIP_MSG=''
      OLDIFS=$IFS; IFS='
'
      for PKG in $PKGLIST; do
        IFS=$OLDIFS
        [ -n "$PKG" ] || continue
        case "$PKG" in ''|*[!a-zA-Z0-9._-]*) continue ;; esac
        # 保护名单同 clean_cache: 缓存敏感应用跳过
        SKIP=0
        for rk in $PKG_CACHE_RISK; do
          case "$PKG" in *"$rk"*) SKIP=1; SKIP_MSG="$SKIP_MSG $PKG(敏感)"; break ;; esac
        done
        if [ "$SKIP" -eq 0 ]; then
          case "$FG" in *"$PKG"*) SKIP=1; SKIP_MSG="$SKIP_MSG $PKG(前台)" ;; esac
        fi
        if [ "$SKIP" -eq 1 ]; then SKIP_CNT=$((SKIP_CNT + 1)); continue; fi
        if [ -n "$NSH" ]; then
          $NSH sh -c 'rm -rf "/data/data/'"$PKG"'/code_cache"/* "/data/data/'"$PKG"'/cache"/*' 2>/dev/null
          $NSH sh -c "[ -d '/data/data/$PKG' ]" 2>/dev/null && OK_CNT=$((OK_CNT + 1)) || FAIL_CNT=$((FAIL_CNT + 1))
        else
          rm -rf "/data/data/$PKG/code_cache"/* "/data/data/$PKG/cache"/* 2>/dev/null
          [ -d "/data/data/$PKG" ] && OK_CNT=$((OK_CNT + 1)) || FAIL_CNT=$((FAIL_CNT + 1))
        fi
      done
      IFS=$OLDIFS
      MSG="已清理 $OK_CNT 个应用"
      [ "$SKIP_CNT" -gt 0 ] && MSG="$MSG, 跳过 $SKIP_CNT 个$SKIP_MSG"
      [ "$FAIL_CNT" -gt 0 ] && MSG="$MSG, 失败 $FAIL_CNT 个"
      add_res "$ACT" ok "$MSG"
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
    # v3.4.9: AI 白名单管理动作 — 持久化写入用户白名单文件
    # whitelist add <包名>: 追加到用户白名单 (kill_guard 以后不再杀该包)
    # whitelist remove <包名>: 从用户白名单移除
    # 安全护栏: PKG_PROTECTED 系统应用禁止加入 (否则 kill_guard 永久失效)
    whitelist\ add\ *)
      PKG=$(echo "$ACT" | awk '{print $3}')
      case "$PKG" in ''|*[!a-zA-Z0-9._-]*) add_res "$ACT" fail "无效包名"; return ;; esac
      case " $PKG_PROTECTED " in *" $PKG "*) add_res "$ACT" skip "跳过系统/宿主应用 $PKG"; return ;; esac
      if is_pkg_whitelisted "$PKG"; then add_res "$ACT" skip "$PKG 已在白名单"; return; fi
      if printf '%s\n' "$PKG" >> "$WL_FILE" 2>/dev/null; then
        PKG_WHITELIST="$PKG_WHITELIST $PKG"
        add_res "$ACT" ok "已将 $PKG 加入白名单"
      else
        add_res "$ACT" fail "写入白名单失败"
      fi
      ;;
    whitelist\ remove\ *)
      PKG=$(echo "$ACT" | awk '{print $3}')
      case "$PKG" in ''|*[!a-zA-Z0-9._-]*) add_res "$ACT" fail "无效包名"; return ;; esac
      if ! is_pkg_whitelisted "$PKG"; then add_res "$ACT" skip "$PKG 不在白名单"; return; fi
      case " $PKG_PROTECTED " in *" $PKG "*) add_res "$ACT" skip "系统应用 $PKG"; return ;; esac
      if grep -vx "$PKG" "$WL_FILE" > "$WL_FILE.tmp" 2>/dev/null && mv "$WL_FILE.tmp" "$WL_FILE"; then
        PKG_WHITELIST=$(printf '%s' "$PKG_WHITELIST" | tr ' ' '\n' | grep -vx "$PKG" | tr '\n' ' ')
        add_res "$ACT" ok "已将 $PKG 移出白名单"
      else
        add_res "$ACT" fail "移出白名单失败"
        rm -f "$WL_FILE.tmp" 2>/dev/null
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
      # v3.4.22: 媒体播放保护 — 冻结播放中应用会立即停止播放
      if is_media_playing "$PKG"; then add_res "$ACT" skip "跳过正在播放音频 $PKG"; return; fi
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

# ---- v3.4.32: 应急解锁动作 (锁机木马防护的执行侧) ----
# 供 AI actions / 面板按钮调用, 格式 emergency_unblock <子动作> [参数]
# 子动作 (全部包名白名单校验, 拒绝任意 shell 注入):
#   freeze <pkg>           禁用恶意应用 (pm disable-user, 可逆, 优先用)
#   uninstall <pkg>        卸载恶意应用 (pm uninstall)
#   remove_admin <pkg/cls> 撤销设备管理器 (dpm remove-active-admin, 锁机恢复关键)
#   clear_overlay <pkg>    关悬浮窗权限 (cmd appops set ... SYSTEM_ALERT_WINDOW ignore)
#   lockscreen_clear       清锁屏凭据 (rm locksettings.db*, 需重启生效; 慎用)
do_emergency() {
  ACT="$1"
  SUB=$(echo "$ACT" | awk '{print $2}')
  ARG=$(echo "$ACT" | awk '{print $3}')
  # lockscreen_clear / disable_accessibility 无需参数, 直接放行
  if [ "$SUB" != 'lockscreen_clear' ] && [ "$SUB" != 'disable_accessibility' ]; then
    # 包名/组件名严格校验: 只允许 [A-Za-z0-9._-], 拒绝 shell 元字符
    case "$ARG" in
      ''|*[!A-Za-z0-9._-]*) add_res "$ACT" fail "参数非法或缺失 (仅允许包名/组件名)"; return ;;
    esac
  fi
  case "$SUB" in
    freeze)
      if pm disable-user "$ARG" >/dev/null 2>&1; then add_res "$ACT" ok "已禁用 $ARG"
      else add_res "$ACT" fail "禁用 $ARG 失败 (应用不存在或系统组件)"; fi
      ;;
    uninstall)
      if pm uninstall "$ARG" >/dev/null 2>&1; then add_res "$ACT" ok "已卸载 $ARG"
      else add_res "$ACT" fail "卸载 $ARG 失败"; fi
      ;;
    remove_admin)
      if dpm remove-active-admin "$ARG" >/dev/null 2>&1; then add_res "$ACT" ok "已撤销设备管理器 $ARG"
      else add_res "$ACT" fail "撤销 $ARG 失败 (它可能已不是活跃设备管理器)"; fi
      ;;
    clear_overlay)
      if cmd appops set "$ARG" SYSTEM_ALERT_WINDOW ignore >/dev/null 2>&1; then add_res "$ACT" ok "已关闭 $ARG 悬浮窗权限"
      else add_res "$ACT" fail "关闭 $ARG 悬浮窗失败"; fi
      ;;
    # v3.4.32: 无障碍锁机恢复 — 清空辅助服务列表 (无障碍锁机 = 恶意应用拿辅助服务后模拟点击绕验证)
    # 参数为包名时只移除该包, 无参数时清空整个列表
    disable_accessibility)
      if [ -z "$ARG" ]; then
        # v3.4.32: 清空全部辅助服务 (无障碍锁机应急)
        settings put secure enabled_accessibility_services "" 2>/dev/null
        settings put secure accessibility_enabled 0 2>/dev/null
        add_res "$ACT" ok "已清空全部辅助服务 (无障碍锁机应急; 系统服务需重新在设置中开启)"
      else
        # 只移除指定包: 读当前列表过滤掉目标包再写回
        _CUR_ACC=$(settings get secure enabled_accessibility_services 2>/dev/null)
        case "$_CUR_ACC" in null|'') _CUR_ACC='' ;; esac
        _NEW_ACC=$(printf '%s' "$_CUR_ACC" | tr ':' '\n' | grep -v "^$ARG" | paste -sd':' - 2>/dev/null)
        settings put secure enabled_accessibility_services "$_NEW_ACC" 2>/dev/null
        add_res "$ACT" ok "已从辅助服务列表移除 $ARG (剩余: ${_NEW_ACC:-无})"
      fi
      ;;
    lockscreen_clear)
      rm -rf /data/system/locksettings.db /data/system/locksettings.db-journal /data/system/locksettings.db-wal /data/system/locksettings.db-shm 2>/dev/null
      add_res "$ACT" ok "已清除锁屏凭据数据库 (重启后生效; 若设备已设密码, 谨慎使用)"
      ;;
    *)
      add_res "$ACT" fail "未知子动作 $SUB (可用: freeze/uninstall/remove_admin/clear_overlay/lockscreen_clear)"
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
  # v3.4.22: 媒体播放列表传给 awk (正在播放音频的应用不杀)
  MPKGS=$(detect_media_playing 2>/dev/null)
  # v3.4.24: RSS 阈值自适应 — 旧固定值 302920KB(296MB) 是 4GB 设备时代的设定,
  # 8GB 设备上 296MB+ 进程太少导致一键优化"永远 killed:0" (实测 before:65→after:65)
  # 新策略: 基础阈值 = 总内存的 3% (8GB→232MB, 4GB→116MB, 12GB→348MB)
  #         压力升档: PSI mem some avg10 > 30 (真实内存停滞) 时阈值降 40% (8GB→139MB)
  #         下限 81920KB(80MB): 再低会误杀系统常驻小进程
  MEM_TOTAL_KB=$(awk '/^MemTotal:/{print $2}' /proc/meminfo 2>/dev/null)
  case "$MEM_TOTAL_KB" in ''|*[!0-9]*) MEM_TOTAL_KB=7733500;; esac   # 兜底 8GB
  RSS_MIN_KB=$(( MEM_TOTAL_KB / 33 ))     # 3%
  # PSI some avg10 (内存阻塞率)
  PSI_S10=$(awk '/^some/{for(i=2;i<=NF;i++){split($i,kv,"=");if(kv[1]=="avg10")print kv[2]}}' /proc/pressure/memory 2>/dev/null)
  case "$PSI_S10" in ''|*[!0-9.]*) PSI_S10=0;; esac
  if awk -v p="$PSI_S10" 'BEGIN{exit !(p>30)}'; then
    RSS_MIN_KB=$(( RSS_MIN_KB * 3 / 5 ))   # 压力大, 降 40% 阈值
  fi
  # 下限 80MB
  [ "$RSS_MIN_KB" -lt 81920 ] && RSS_MIN_KB=81920
  ps -A -o pid,rss,comm 2>/dev/null | awk -v resfile="$RESFILE" -v prot="$PROTECTED $PKG_PROTECTED" -v host="$HOST_PROTECTED" -v wl="$PKG_WHITELIST" -v fg="$FGP" -v mp="$MPKGS" -v minrss="$RSS_MIN_KB" '
  BEGIN { split(prot, P, " "); np = 0; for (k in P) { np++; KEYS[np] = P[k] }; split(host, H, " "); nh = 0; for (k in H) { nh++; HK[nh] = H[k] }; split(wl, W, " "); nw = 0; for (k in W) { nw++; WL[nw] = W[k] };_nm = split(mp, M, " ") }
  $1 ~ /^[0-9]+$/ && $2 ~ /^[0-9]+$/ && $2 >= minrss {
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
    # v3.4.22: 媒体播放保护 — 正在播放音频的应用不杀 (mp 列表由 optimize 主体传入)
    if (!skip && _nm > 0) {
      wp2 = lcmd; wi2 = index(wp2, ":"); if (wi2 > 0) wp2 = substr(wp2, 1, wi2 - 1)
      for (k2 = 1; k2 <= _nm; k2++) { if (wp2 == M[k2]) { skip = 1; reason = "正在播放音频"; break } }
    }
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
  # v3.4.70: killed=0 时的友好提示 — 大进程全在保护名单 = 设备整洁, 不是清理失败
  if [ "$KILLED" -eq 0 ]; then
    add_res "status" ok "✅ 系统整洁, 无需清理 (大内存进程均在保护名单内)"
  else
    add_res "status" ok "已结束 $KILLED 个后台进程, 释放 $((BEFORE - AFTER))% 内存"
  fi
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