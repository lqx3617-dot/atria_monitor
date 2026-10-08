#!/system/bin/sh
# Atria Monitor v3.4.84 - 格机防护守护进程 (anti-wipe guard daemon)
# 实测依据: dumpsys device_policy 38ms/次, ps -A 880进程 50ms, grep /proc/cmdline 70ms
# 拦截手段: pm disable-user --user 0 (实测有效, remove-active-admin 要求 testOnly 对木马无效)
# v3.4.80: 触发拦截时彻底删除威胁文件 (APK + 数据目录), 断根防止复活
# v3.4.81: 新增进程命令行扫描层 — 拦截 rm -rf /data|/system、mkfs、dd 覆写块设备等 sh 脚本格机
# 架构照抄 install_watch.sh: 单例锁(PID+cmdline) + setsid 脱离进程组 + 轮询不阻塞管道
# 白名单: 系统包 + 宿主助手 + /data/adb/atria_guard_whitelist.conf (模块目录外, 更新不丢失)
PATH=/system/bin:/system/xbin:/sbin:/vendor/bin:$PATH

DIR=$(dirname "$0")
LOCK=/data/local/tmp/atria_guard_watch.lock
LOG=/data/local/tmp/atria_guard_log.jsonl
STATE=/data/local/tmp/atria_guard_state.json
WL_FILE=/data/adb/atria_guard_whitelist.conf
BASE=/data/local/tmp/atria_guard_baseline.txt

# ---- 单例检查 (同 service.sh: PID 存活 + cmdline 身份双校验, 防 PID 复用) ----
if [ -r "$LOCK" ]; then
  OPID=$(cat "$LOCK" 2>/dev/null)
  case "$OPID" in ''|*[!0-9]*) ;; *)
    if [ -d /proc/"$OPID" ] && grep -q guard_watch /proc/"$OPID"/cmdline 2>/dev/null; then
      exit 0
    fi
    ;;
  esac
fi
echo $$ > "$LOCK"

# ---- 默认白名单: 系统包前缀 + 宿主助手 + 已知合法应用 ----
# 与 inject_security 的放行列表保持一致 (com.android.* / 宿主 / 输入法 / launcher)
DEF_WL="com.android com.google com.oplus com.heytap com.coloros com.oppo com.ai.assistance.operit com.niki914.zafiro com.iflytek.inputmethod com.gtq.launcher"

# ---- 加载用户白名单 (模块目录外, 模块更新不丢失; 每轮重读, 改了立即生效) ----
load_wl() {
  _U=''
  if [ -f "$WL_FILE" ]; then
    # 过滤注释行与空行, 只留合法包名/前缀
    _U=$(grep -vE '^\s*(#|$)' "$WL_FILE" 2>/dev/null | tr -d ' \t\r' | tr '\n' ' ')
  fi
  printf '%s' "$_U"
}

# ---- JSON 字符串转义 (防引号/反斜杠破坏 jsonl) ----
json_esc() {
  printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'
}

# ---- 白名单判定: 前缀匹配 ----
# 用法: is_wl <包名> ; 返回 0=放行 1=拦截
is_wl() {
  _P="$1"
  for _W in $DEF_WL; do
    case "$_P" in "$_W"*) return 0 ;; esac
  done
  _UWL=$(load_wl)
  for _W in $_UWL; do
    [ -z "$_W" ] && continue
    case "$_P" in "$_W"*) return 0 ;; esac
  done
  return 1
}

# ---- 基线: 首次运行记录当前已激活的设备管理器 (之后只对新增的陌生 admin 拦截) ----
# 已存在的 admin 若在白名单内则放行; 不在白名单内也不拦截 (可能是用户在装防护前主动激活的)
# 只拦截"基线建立后新出现且不在白名单内"的 admin — 避免误拦用户既有配置
if [ ! -s "$BASE" ]; then
  timeout 5 dumpsys device_policy 2>/dev/null \
    | grep -oE 'Admin: ComponentInfo\{[^}]+\}' \
    | sed 's/.*ComponentInfo{//; s/}$//; s/\/.*//' > "$BASE" 2>/dev/null
fi

# ---- v3.4.80: 彻底删除威胁文件 (APK + 数据目录) ----
# 传参: 包名。删除 apk 路径 + /data/data 目录 + /data/user_de 目录
# 返回: 删除的 apk 文件数 (0=没找到或失败); 数据目录删除不计入此计数
# 注意: 不用 while read 管道 (fork 子 shell 计数丢失), 不用 /tmp (Android 可能不存在)
kill_files() {
  _KP="$1"
  _N=0
  # APK 路径 (pm path 可能返回多段 base/split, 全删; 路径不含空格, for 循环安全)
  _APKS=$(timeout 5 pm path "$_KP" 2>/dev/null | sed 's/^package://; s/\r$//')
  for _A in $_APKS; do
    [ -z "$_A" ] && continue
    # 路径合法性校验: 必须在 /data/app 下, 防注入删错文件
    case "$_A" in
      /data/app/*) rm -f "$_A" 2>/dev/null && _N=$((_N + 1)) ;;
    esac
  done
  # 数据目录 (用户态 + 用户加密态 + 多用户)
  rm -rf "/data/data/$_KP" 2>/dev/null
  rm -rf "/data/user_de/0/$_KP" 2>/dev/null
  rm -rf "/data/user/0/$_KP" 2>/dev/null
  printf '%s' "$_N"
}

# ---- v3.4.81: 杀进程树 (含子进程, 防止 rm -rf 的子 shell 继续删) ----
# 传参: PID。先杀父进程再遍历子进程, 用 pkill -P 处理多子进程
kill_proc_tree() {
  _TP="$1"
  [ -z "$_TP" ] && return
  # 先递归收集子 PID (防止先杀父后子进程变孤儿找不到)
  _SUBS=$(ps -A -o PID,PPID 2>/dev/null | awk -v p="$_TP" '$2 == p {print $1}')
  # 杀父
  kill -9 "$_TP" 2>/dev/null
  # 杀子
  for _S in $_SUBS; do
    [ -z "$_S" ] && continue
    kill -9 "$_S" 2>/dev/null
  done
}

# ---- v3.4.81: 进程命令行扫描 — 检测 sh 脚本格机命令 ----
# 实测: 880 进程预筛 70ms + 命中校验 <5ms, 3 秒窗口绰绰有余
# 误报防护: 预筛用子串 (rm/mkfs/dd), 二次校验用词边界正则排除 keymint/clearkey/wpa_supplicant 等
#   - rm 必须是独立命令词 且带 -rf/-fr 或目标为 /data /system /sdcard /storage 整盘路径
#   - mkfs/mke2fs/make_ext4fs 必须是独立命令词
#   - dd 必须是独立命令词且 if=/of= 指向 /dev/block 或 /dev/mmcblk
# 自身保护: guard_watch 自身 cmdline 不含这些模式; 且扫描在子 shell 中执行, 即使误杀也不影响主循环
# 关键: cmdline 参数以 \0 分隔
#   - grep 词边界正则不认 \0 (rm\0-rf 中 rm 后面不是空格), 预筛必须用子串匹配
#   - 二次校验前必须 tr '\0' ' ' 把参数分隔符转成空格, 词边界正则才生效
# 性能: 预筛 grep -l 批量 (1 次 fork ~70ms), 只对命中的少量文件做 tr+grep 校验
#   - for 循环逐个 cat+grep 会 fork 8800 次卡死主循环, 禁止使用
#   - toybox awk 不支持 ENDFILE, getline 受 RS 影响读不完整 \0 分隔内容, 禁止用 awk
scan_procs() {
  # 输出: 命中条目列表 "PID<TAB>命令行" (每行一条), 供主循环逐条处置
  # 预筛: 子串匹配 (grep -l 对 \0 分隔内容也能子串匹配, 词边界不行)
  grep -lE 'rm|mkfs|mke2fs|make_ext4fs|dd' /proc/[0-9]*/cmdline 2>/dev/null \
    | while IFS= read -r _F; do
        [ -z "$_F" ] && continue
        _PID=$(printf '%s' "$_F" | sed 's|/proc/||; s|/cmdline||')
        # PID 合法性校验
        case "$_PID" in ''|*[!0-9]*) continue ;; esac
        # 跳过自身与父进程 (guard_watch / collect_loop / ksud / sh 主进程)
        case "$_PID" in $$|$PPID) continue ;; esac
        # tr 把 \0 转空格, 词边界正则才生效
        _CMD=$(cat "$_F" 2>/dev/null | tr '\0' ' ')
        # 空 cmdline = 内核线程或已退出进程 — 跳过
        [ -z "$_CMD" ] && continue
        # v3.4.84: 数据载体豁免 — curl/wget/python/node 的命令行参数是"数据"不是"命令",
        # -d body 或 URL 里含 "rm -rf /data" 字样只是文本 (实测误杀: 上传含安全文档的
        # curl 被 wipe_command 杀掉, Release 创建中断)。这些工具不会真执行 rm/mkfs/dd。
        # sh -c 不豁免 (格机脚本就是 sh -c 跑的)。
        case "$_CMD" in
          curl\ *|wget\ *|python\ *|python3\ *|node\ *) continue ;;
        esac
        # 二次校验: 必须命中真正的危险模式 (词边界 + 危险参数/路径)
        # 1) rm 带危险参数 -rf/-fr 且目标是整盘路径 (子路径不杀, 如 rm -rf /data/local/tmp/x 是正常清理)
        #    尾部界定 [^a-zA-Z0-9/]: 允许分号/引号/&/| 等命令分隔符 (rm -rf /data; reboot), 排除子路径斜杠
        #    前缀界定 [^a-zA-Z0-9]: 允许引号包裹 (sh -c "rm -rf /data"), 排除 keymint 等 rm 子串误报
        if printf '%s' "$_CMD" | grep -qE '(^|[^a-zA-Z0-9])rm[[:space:]](-rf|-fr)[[:space:]]+['"'"'"]?(/data|/system|/sdcard|/storage)([^a-zA-Z0-9/]|$)'; then
          printf '%s\t%s\n' "$_PID" "$_CMD"
          continue
        fi
        # 2) rm 直接跟整盘路径 (rm /data, rm /system, 无 -rf 参数也拦截)
        if printf '%s' "$_CMD" | grep -qE '(^|[^a-zA-Z0-9])rm( |$)(-rf[[:space:]]+|-fr[[:space:]]+|-r[[:space:]]+|-f[[:space:]]+)?['"'"'"]?(/data|/system|/sdcard|/storage)([^a-zA-Z0-9/]|$)'; then
          # 排除子路径: /data/ 后面还有内容的放过 (如 rm -rf /data/local/tmp/x)
          if ! printf '%s' "$_CMD" | grep -qE '(^|[^a-zA-Z0-9])rm( |$)(-rf[[:space:]]+|-fr[[:space:]]+|-r[[:space:]]+|-f[[:space:]]+)?['"'"'"]?/(data|system|sdcard|storage)/'; then
            printf '%s\t%s\n' "$_PID" "$_CMD"
            continue
          fi
        fi
        # 3) mkfs / mke2fs / make_ext4fs (格式化)
        if printf '%s' "$_CMD" | grep -qE '(^|[^a-zA-Z0-9])(mkfs|mke2fs|make_ext4fs)( |$|\.)'; then
          if printf '%s' "$_CMD" | grep -qE '(/dev/block|/dev/mmcblk|/data|/system)'; then
            printf '%s\t%s\n' "$_PID" "$_CMD"
            continue
          fi
        fi
        # 4) dd 覆写块设备 (if= 或 of= 指向 /dev/block 或 /dev/mmcblk)
        if printf '%s' "$_CMD" | grep -qE '(^|[^a-zA-Z0-9])dd( |$)'; then
          if printf '%s' "$_CMD" | grep -qE '(if|of)=/dev/(block|mmcblk)'; then
            printf '%s\t%s\n' "$_PID" "$_CMD"
            continue
          fi
        fi
      done
}

# ---- v3.4.84: fd 块设备监控 (用户态 fd 级检测) ----
# 内核态 kprobe/BPF LSM 在本设备不可行 (CONFIG_MODULE_SIG_PROTECT=y 强制签名,
# CONFIG_BPF_LSM 未开启), 改为 fd 级监控: 格机工具 dd 覆写前必须先 open 块设备,
# fd 里会暴露。find -lname 一次性遍历所有进程 fd, 实测 <1s (896 进程)。
# 只抓应用进程 (uid>=10000): 系统进程如 qseecomd 合法访问 /dev/block/sda1。
# 输出格式与 scan_procs 一致: "PID<TAB>命令行"
scan_fds() {
  find /proc/[0-9]*/fd -maxdepth 1 -type l -lname '/dev/block/*' 2>/dev/null \
    | while IFS= read -r _FD; do
        [ -z "$_FD" ] && continue
        _PID=$(printf '%s' "$_FD" | sed 's|/proc/||; s|/fd/.*||')
        case "$_PID" in ''|*[!0-9]*) continue ;; esac
        case "$_PID" in $$|$PPID) continue ;; esac
        # uid 过滤: 只抓应用进程 (>=10000), 系统/root 进程放过
        _UID=$(awk '/^Uid:/{print $2}' "/proc/$_PID/status" 2>/dev/null)
        case "$_UID" in ''|*[!0-9]*) continue ;; esac
        [ "$_UID" -ge 10000 ] || continue
        _CMD=$(cat "/proc/$_PID/cmdline" 2>/dev/null | tr '\0' ' ')
        [ -z "$_CMD" ] && continue
        printf '%s\t%s\n' "$_PID" "$_CMD"
      done
}

# ---- 主循环: 3 秒轮询 ----
# dumpsys 实测 38ms, ps+grep 实测 120ms, timeout 5s 兜底 (卡死时跳过本轮, 保住循环不崩)
while true; do
  _NOW=$(date +%s)
  _ADMINS=0
  _BLOCKED=0
  _LASTPKG=''
  _LASTACT=''
  _DELF=0
  # v3.4.81: _KILLED 是累计值 (跨轮不清零), 前端看到的 killed_procs 是历史总数
  # 本轮新增杀进程数单独记 _KILLED_THIS
  _KILLED_THIS=0
  _KILLPID=''
  _KILLCMD=''

  # 提取当前激活的设备管理器组件 (格式: 包名/组件名)
  _DA=$(timeout 5 dumpsys device_policy 2>/dev/null \
    | grep -oE 'Admin: ComponentInfo\{[^}]+\}' \
    | sed 's/.*ComponentInfo{//; s/}$//')

  if [ -n "$_DA" ]; then
    # 用 for 循环不用 while read 管道 — 管道会 fork 子 shell, 计数变量丢失
    for _C in $_DA; do
      [ -z "$_C" ] && continue
      _PKG=$(printf '%s' "$_C" | cut -d/ -f1)
      # 包名合法性校验 (防注入)
      case "$_PKG" in ''|*[!a-zA-Z0-9._-]*) continue ;; esac
      _ADMINS=$((_ADMINS + 1))

      if is_wl "$_PKG"; then
        # 白名单内: 放行, 不记录
        :
      else
        # 陌生 admin: 立即禁用 (pm disable-user 实测秒级生效)
        _RES=$(pm disable-user --user 0 "$_PKG" 2>&1)
        case "$_RES" in
          *disabled*) _ACT='blocked' ;;
          *) _ACT='block_failed' ;;
        esac
        # v3.4.80: 删除威胁文件 (APK + 数据目录), 断根
        _DELN=$(kill_files "$_PKG")
        _DELF=$((_DELF + _DELN))
        _ESC=$(json_esc "$_C")
        printf '{"ts":%s,"pkg":"%s","comp":"%s","action":"%s","level":"high","reason":"unknown_device_admin","files_deleted":%s}\n' \
          "$_NOW" "$_PKG" "$_ESC" "$_ACT" "$_DELN" >> "$LOG" 2>/dev/null
        _BLOCKED=$((_BLOCKED + 1))
        _LASTPKG="$_PKG"
        _LASTACT="$_ACT"
      fi
    done
  fi

  # ---- v3.4.81: 进程命令行扫描 (sh 脚本格机检测) ----
  # 实测 70ms, 与 dumpsys 38ms 串行总计 ~110ms, 3 秒周期内 CPU 占用 <4%
  _HITS=$(scan_procs)
  if [ -n "$_HITS" ]; then
    # 用 while read 按行迭代, 不用 for (for 按空格分词会把 CMD 拆开, 'sleep 30' 的 30 会被当 PID 误杀)
    # 用 here-string 不用管道 (管道 fork 子 shell, _KILLED_THIS 累加会丢失)
    while IFS= read -r _H; do
      [ -z "$_H" ] && continue
      _HPID=$(printf '%s' "$_H" | cut -f1)
      _HCMD=$(printf '%s' "$_H" | cut -f2-)
      # PID 合法性校验 (防注入)
      case "$_HPID" in ''|*[!0-9]*) continue ;; esac
      # 跳过自身与父进程 (双保险, scan_procs 内已跳过一次)
      case "$_HPID" in $$|$PPID) continue ;; esac
      # CMD 为空说明该行格式错误 (无 tab 分隔), 跳过
      [ -z "$_HCMD" ] && continue
      # 杀进程树 (含子进程, 防止 rm -rf 的子 shell 继续删)
      kill_proc_tree "$_HPID"
      _KILLED_THIS=$((_KILLED_THIS + 1))
      _KILLPID="$_HPID"
      _KILLCMD="$_HCMD"
      # 记日志 (命令行截断前 100 字符, 防 jsonl 膨胀)
      _ESCC=$(json_esc "$(printf '%s' "$_HCMD" | cut -c1-100)")
      printf '{"ts":%s,"pkg":"pid:%s","comp":"%s","action":"killed","level":"high","reason":"wipe_command","files_deleted":0}\n' \
        "$_NOW" "$_HPID" "$_ESCC" >> "$LOG" 2>/dev/null
    done <<< "$_HITS"
  fi

  # ---- v3.4.84: fd 块设备监控 (应用进程打开块设备 = 格机前兆) ----
  # 与 scan_procs 复用同一处置链 (杀进程树 + 记日志), reason 区分
  _FDHITS=$(scan_fds)
  if [ -n "$_FDHITS" ]; then
    while IFS= read -r _FH; do
      [ -z "$_FH" ] && continue
      _FPID=$(printf '%s' "$_FH" | cut -f1)
      _FCMD=$(printf '%s' "$_FH" | cut -f2-)
      case "$_FPID" in ''|*[!0-9]*) continue ;; esac
      case "$_FPID" in $$|$PPID) continue ;; esac
      [ -z "$_FCMD" ] && continue
      kill_proc_tree "$_FPID"
      _KILLED_THIS=$((_KILLED_THIS + 1))
      _KILLPID="$_FPID"
      _KILLCMD="$_FCMD"
      _ESCF=$(json_esc "$(printf '%s' "$_FCMD" | cut -c1-100)")
      printf '{"ts":%s,"pkg":"pid:%s","comp":"%s","action":"killed","level":"high","reason":"block_device_fd","files_deleted":0}\n' \
        "$_NOW" "$_FPID" "$_ESCF" >> "$LOG" 2>/dev/null
    done <<< "$_FDHITS"
  fi

  # ---- 写状态文件 (单行 JSON, 供前端 15s 轮询读取) ----
  # level: ok=无威胁 / high=本轮有拦截或杀进程
  # v3.4.81: killed_procs 为累计值 — 本轮有新增则累加, 无新增保持上轮值
  if [ "$_BLOCKED" -gt 0 ] || [ "$_KILLED_THIS" -gt 0 ]; then
    _LVL='high'
  else
    _LVL='ok'
  fi
  # 累计 killed_procs: 从 state 文件读上轮值, 加本轮新增
  _PREV_KILLED=0
  if [ -r "$STATE" ]; then
    _PK=$(grep -o '"killed_procs":[0-9]*' "$STATE" 2>/dev/null | cut -d: -f2)
    case "$_PK" in *[!0-9]*) _PK='' ;; esac
    [ -n "$_PK" ] && _PREV_KILLED="$_PK"
  fi
  _KILLED=$((_PREV_KILLED + _KILLED_THIS))
  _LPKG=$(json_esc "$_LASTPKG")
  _LACT=$(json_esc "$_LASTACT")
  # v3.4.81: 新增 killed_procs (累计杀掉的格机进程数) 与 last_kill (最近杀掉的命令)
  _LKILL=$(json_esc "$(printf '%s' "$_KILLCMD" | cut -c1-60)")
  # v3.4.81: 原子写 — 先写临时文件再 mv, 防止前端读到写一半的截断 JSON
  printf '{"level":"%s","admins":%s,"blocked":%s,"files_deleted":%s,"killed_procs":%s,"last_pkg":"%s","last_action":"%s","last_kill":"%s","ts":%s,"running":1}\n' \
    "$_LVL" "$_ADMINS" "$_BLOCKED" "$_DELF" "$_KILLED" "$_LPKG" "$_LACT" "$_LKILL" "$_NOW" > "${STATE}.tmp" 2>/dev/null
  mv -f "${STATE}.tmp" "$STATE" 2>/dev/null

  # ---- 日志轮转: 超过 200 行只保留尾部 150 行 ----
  # wc 读不存在的文件会报错刷屏 — 先判存在再读
  if [ -f "$LOG" ]; then
    _LC=$(wc -l < "$LOG" 2>/dev/null)
    case "$_LC" in *[!0-9]*) _LC=0 ;; esac
    if [ "$_LC" -gt 200 ]; then
      tail -150 "$LOG" > /tmp/.gw_rot_$$.txt 2>/dev/null && mv /tmp/.gw_rot_$$.txt "$LOG" 2>/dev/null
    fi
  fi
  rm -f /tmp/.gw_rot_$$.txt 2>/dev/null

  sleep 3
done