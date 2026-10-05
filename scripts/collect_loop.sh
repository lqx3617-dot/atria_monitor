#!/system/bin/sh
# Atria Monitor v3.4.34 - 后台采集循环
# v3.2.36: 白名单图标后台刷新 (refresh_icons, 检测白名单 mtime 变化, 后台提取不阻塞采集)
# v3.2.34: 补全 PATH (开机服务阶段 PATH 可能残缺)
export PATH=/system/bin:/system/xbin:/sbin:/vendor/bin:$PATH
# v3.1.9 修复:
#   1) 采集周期 2s -> 4s, 与前端 4s 轮询对齐 (v3.1.8 一半采集结果从未被读取, 纯浪费)
#   2) 息屏自动降频到 30s (v3.1.8 熄屏后仍每 2s 唤醒 CPU 跑 logcat/ps/awk, 严重影响待机)
#   3) 采集结果经 JSON 合法性校验后才写入 (v3.1.8 失败时残留 .new / 静默展示旧数据)
#   4) 启动时自检锁归属, 发现锁不属于自己则退出 (配合 service.sh 的单例修复)
# v3.2.34 新增:
#   1) 历史落盘: 每 HIST_EVERY 次采样追加一行到 jsonl, 面板可回看几小时趋势
#   2) 历史自动轮转: 超过 HIST_MAX_BYTES 时保留后半段 + 每日 truncate, 防止无限增长
#   3) 状态 JSON 加入 history_len 字段, 面板据此提示"有可回看历史"
DIR=$(dirname "$0")
OUT=/data/local/tmp/atria_status.json
# v3.2.34: 优先用 C 采集器 (arm64, ~13KB, 比 shell 快 6-8 倍), 不可用时回退 shell
CBIN="$DIR/../native/collect_c_arm64"
[ -x "$CBIN" ] || CBIN=''
USE_C=0
if [ -n "$CBIN" ]; then
  # v3.2.34: 探测改用 awk 取首字节 (head -c 1 提前退出会触发 C 程序 SIGPIPE)
  PROBE=$("$CBIN" 2>/dev/null | awk '{printf "%s", substr($0,1,1); exit}')
  if [ "$PROBE" = "{" ]; then USE_C=1; fi
fi
LOCK=/data/local/tmp/atria_monitor.lock
# v3.2.36: 白名单图标提取
IBIN="$DIR/../native/icon_extract_c_arm64"
# 图标目录必须放 /data/local/tmp: WebView 以 App UID 渲染, 无法读取 /data/adb (0700)
ICONDIR=/data/local/tmp/atria_icons
WL_FILE=/data/adb/atria_whitelist.conf
WL_MTIME=0
ICON_TICK=0
# v3.2.34: 历史文件放 root 专属目录, 避免世界可写目录被篡改
HIST=/data/adb/atria_history.jsonl
# v3.2.94: 镜像到 /data/local/tmp (644) 供 WebView fetch 直读, 绕开 exec 单行截断
HIST_MIRROR=/data/local/tmp/atria_history.jsonl
# v3.2.94: 显式 umask 022, 落盘文件保持 644 (WebView 以 App UID 运行, 需 other 可读)
umask 022
# v3.2.93: hist_extract 输出偶发全零行 (ts=0), 面板 loadHistory 已跳过零行并回退扩大读取窗口
INTERVAL=4
IDLE_INTERVAL=30
# v3.2.34: 每 3 次采样落盘一次 (~12s 一条, 24h 约 7200 条 ≈ 1.5MB)
HIST_EVERY=3
HIST_MAX_BYTES=2097152
# v3.2.36: 白名单 mtime 变化时后台提取图标 (不阻塞采集主循环)
# stat -c %Y 与 date -r +%s 均可用, stat 优先, date -r 兜底
refresh_icons() {
  [ -x "$IBIN" ] || return 0
  [ -r "$WL_FILE" ] || return 0
  MT=0
  if command -v stat >/dev/null 2>&1; then
    MT=$(stat -c %Y "$WL_FILE" 2>/dev/null)
  fi
  case "$MT" in ''|*[!0-9]*)
    MT=$(date -r "$WL_FILE" +%s 2>/dev/null)
    ;;
  esac
  case "$MT" in ''|*[!0-9]*) return 0;; esac
  if [ "$MT" = "$WL_MTIME" ]; then return 0; fi
  WL_MTIME=$MT
  mkdir -m 0755 -p "$ICONDIR" 2>/dev/null
  ( "$IBIN" --whitelist "$WL_FILE" "$ICONDIR" >/dev/null 2>&1; chmod 0644 "$ICONDIR"/* 2>/dev/null ) &
  plog "INFO 图标刷新 (白名单 mtime=$MT)"
}

# v3.2.34: 后端运行日志 (面板可从此文件排查采集问题, 滚动保留 200 行)
PLOG=/data/local/tmp/atria_collect.log
# v3.2.34: 日志滚动改为按写入计数触发 (原每次 plog 都 fork wc 统计行数)
_PLOG_CNT=0
. "$DIR/atria_inject98.sh"   # v3.2.98: wakelock + du 注入函数
# v3.4.20: 应用名标签缓存 tick (每 300 周期刷一次, 初始化 300 = 首个周期立即生成)
LB_TICK=300
plog() {
  echo "$(date '+%H:%M:%S') $1" >> "$PLOG" 2>/dev/null
  _PLOG_CNT=$((_PLOG_CNT + 1))
  # 每 200 次写入滚动一次, 而非每次写入都 fork wc
  if [ "$_PLOG_CNT" -ge 200 ]; then
    _PLOG_CNT=0
    tail -n 200 "$PLOG" > "$PLOG.new" 2>/dev/null && mv "$PLOG.new" "$PLOG" 2>/dev/null
  fi
}

# v3.1.9: 锁归属自检 - 若锁内 PID 存活但不是本进程, 说明被重复拉起
if [ -r "$LOCK" ]; then
  OPID=$(cat "$LOCK" 2>/dev/null)
  case "$OPID" in ''|*[!0-9]*) ;; *)
    if [ "$OPID" != "$$" ] && [ -d /proc/"$OPID" ]; then
      # 确认那个进程确实是 collect_loop, 避免误判 (PID 复用)
      if grep -q collect_loop /proc/"$OPID"/cmdline 2>/dev/null; then
        exit 0
      fi
    fi
    ;;
  esac
fi
echo $$ > "$LOCK" 2>/dev/null

# v3.2.34: 息屏检测带 10s 缓存 (原每次采样都 fork dumpsys+grep, 息屏时 30s 一采也跑)
# 缓存期内直接返回上次结果, 状态变化时最多延迟 10s 生效
_SCREEN_CACHE=""
_SCREEN_CACHE_AT=0
is_screen_off() {
  now=$(date +%s)
  if [ "$((now - _SCREEN_CACHE_AT))" -lt 10 ] && [ -n "$_SCREEN_CACHE" ]; then
    [ "$_SCREEN_CACHE" = "off" ] && return 0 || return 1
  fi
  _SCREEN_CACHE_AT=$now
  if command -v dumpsys >/dev/null 2>&1; then
    if dumpsys power 2>/dev/null | grep -q 'mScreenDisplayState=OFF\|mWakefulness=Asleep'; then
      _SCREEN_CACHE=off; return 0
    fi
    _SCREEN_CACHE=on; return 1
  fi
  for b in /sys/class/backlight/*/brightness /sys/class/leds/lcd-backlight/brightness; do
    if [ -r "$b" ]; then
      if [ "$(cat "$b" 2>/dev/null)" = "0" ]; then
        _SCREEN_CACHE=off; return 0
      fi
      _SCREEN_CACHE=on; return 1
    fi
  done
  _SCREEN_CACHE=on; return 1
}

# v3.2.34: 从完整状态 JSON 提取需要落盘的精简字段 (单 awk, 0 额外 fork)
# 输出: {"ts":...,"mem":..,"cpu":..,"temp":..,"batt":..,"stor":..,"net_rx":..,"net_tx":..}
hist_extract() {
  printf '%s\n' "$1" | awk '{
    # 提取数值字段: 用匹配定位再截取, 避免完整 JSON 解析
    ts = 0; mem = 0; cpu = 0; temp = 0; batt = -1; stor = -1
    # v3.2.34: 偏移 = 前缀长度 (":"也算), RLENGTH 含整个匹配
    if (match($0, /"timestamp":[0-9]+/)) ts = substr($0, RSTART + 12, RLENGTH - 12)
    if (match($0, /"percent":[0-9]+/)) mem = substr($0, RSTART + 10, RLENGTH - 10)
    if (match($0, /"cpu":\{"percent":[0-9]+\}/)) {
      seg = substr($0, RSTART, RLENGTH)
      # v3.2.34: split 取冒号后数值, 避开嵌套 match 的 RSTART 冲突
      nc = split(seg, cp, ":")
      cv = cp[nc]
      gsub(/[^0-9]/, "", cv)
      cpu = cv + 0
    }
    if (match($0, /"temp":[0-9.]+/)) temp = substr($0, RSTART + 7, RLENGTH - 7) + 0
    if (match($0, /"capacity":-?[0-9]+/)) batt = substr($0, RSTART + 11, RLENGTH - 11) + 0
    # v3.2.34: 只取 storage 段的 percent (mem 的 percent 在前面, 会误匹配)
    if (match($0, /"storage":\[\{"mount":"[^"]*","total_gb":[0-9.]+,"used_gb":[0-9.]+,"free_gb":[0-9.]+,"percent":[0-9]+\}/)) {
      seg = substr($0, RSTART, RLENGTH)
      ns = split(seg, sp, ":")
      sv = sp[ns]
      gsub(/[^0-9]/, "", sv)
      stor = sv + 0
    }
    # 网络取主设备 rx/tx (取最大的 rx)
    rx = 0; tx = 0
    s = $0
    while (match(s, /"rx_bytes":[0-9]+/)) {
      v = substr(s, RSTART + 11, RLENGTH - 11) + 0
      if (v > rx) rx = v
      s = substr(s, RSTART + RLENGTH)
    }
    s = $0
    while (match(s, /"tx_bytes":[0-9]+/)) {
      v = substr(s, RSTART + 11, RLENGTH - 11) + 0
      if (v > tx) tx = v
      s = substr(s, RSTART + RLENGTH)
    }
    printf "{\"ts\":%s,\"mem\":%s,\"cpu\":%s,\"temp\":%s,\"batt\":%s,\"stor\":%s,\"rx\":%d,\"tx\":%d}\n", ts, mem, cpu, temp, (batt < 0 ? 0 : batt), (stor < 0 ? 0 : stor), rx, tx
  }' 2>/dev/null
}

# v3.2.34: 历史轮转 - 超限时保留后半段 (截到行边界, 不产生半行)
hist_rotate() {
  [ -f "$HIST" ] || return 0
  SZ=$(wc -c < "$HIST" 2>/dev/null)
  case "$SZ" in ''|*[!0-9]*) return 0;; esac
  [ "$SZ" -le "$HIST_MAX_BYTES" ] && return 0
  # 保留后半段,再用 tail 兜底行边界
  tail -c $((HIST_MAX_BYTES / 2)) "$HIST" 2>/dev/null | tail -n +2 > "$HIST.new" 2>/dev/null
  if [ -s "$HIST.new" ]; then
    mv "$HIST.new" "$HIST" 2>/dev/null
    # v3.2.94: 轮转后镜像也截取后半段
    tail -c $((HIST_MAX_BYTES / 2)) "$HIST" 2>/dev/null > "$HIST_MIRROR" 2>/dev/null
    chmod 644 "$HIST_MIRROR" 2>/dev/null
    chmod 644 "$HIST" 2>/dev/null
  else
    rm -f "$HIST.new" 2>/dev/null
  fi
}

COUNT=0
SAMPLES=0
C_RETRY_AT=999999   # v3.2.34: 首次回退时才设置重试点
# v3.2.35: C 采集器不输出 modules, shell 补充 (带缓存, 每 MODS_REFRESH 次采样刷新)
MODS_CACHE=''
MODS_CNT=0
MODS_REFRESH=60
MROOT=/data/adb/modules
[ -d "$MROOT" ] || MROOT=/data/adb/ap/modules
scan_mods() {
  if [ -n "$MODS_CACHE" ] && [ "$MODS_CNT" -lt "$MODS_REFRESH" ]; then
    MODS_CNT=$((MODS_CNT + 1))
    printf '%s' "$MODS_CACHE"
    return
  fi
  MODS_CNT=1
  MODS_CACHE=''
  for mp in "$MROOT"/*/module.prop; do
    [ -r "$mp" ] || continue
    d=$(dirname "$mp"); mid=${d##*/}
    name=$mid; en=true
    while IFS= read -r line; do
      case "$line" in name=*) name=${line#name=}; name=${name%$'\r'};; esac
    done < "$mp" 2>/dev/null
    [ -e "$d/disable" ] && en=false
    case "$name" in *'>'*|*'<'*|'&'*|*'"'*) name=$mid;; esac
    MODS_CACHE="$MODS_CACHE{\"name\":\"$name\",\"id\":\"$mid\",\"enabled\":$en},"
  done
  printf '%s' "$MODS_CACHE"
}
# v3.2.35: 注入 modules 字段 (C 采集器输出 "modules":[], 替换为真实列表)
inject_mods() {
  IN=$(cat)
  ML=$(scan_mods)
  if [ -n "$ML" ]; then
    printf '%s' "$IN" | sed "s/\"modules\":\[\]/\"modules\":[${ML%,}]/"
  else
    printf '%s' "$IN"
  fi
}
# v3.2.35: C 采集器 storage 显示为 /data, 统一为 /storage/emulated (与 shell 版一致)
# v3.2.92: inject cpu pct (top sees all procs in root shell domain, proot only 23)
inject_cpu() {
  # v3.2.92: 表头驱动定位 %CPU 列 (不同 top 版本列号不同, S[%CPU] 粘连时数值在下一字段)
  RAW=$(top -n 1 -b 2>/dev/null)
  HDR=$(printf '%s\n' "$RAW" | grep -n 'PID' | head -1 | cut -d: -f1)
  [ -n "$HDR" ] || return 0
  CPUCOL=$(printf '%s\n' "$RAW" | sed -n "${HDR}p" | awk '{for(i=1;i<=NF;i++) if($i ~ /%CPU/) {print i+1; exit}}')
  [ -n "$CPUCOL" ] || return 0
  TOPMAP=$(printf '%s\n' "$RAW" | sed -n "$((HDR+1)),\$p" | awk -v c="$CPUCOL" '{print $1 ":" $c}')
  [ -n "$TOPMAP" ] || return 0
  # v3.2.92: 单次 sed 批量替换 — 原实现对每个 pid 各 fork 一次 printf+sed
  # (top 约 870 进程 => 1740 次 fork, 实测单轮采集 89 秒, 周期从 4s 涨到 89s)
  # 改为一次 sed 应用全部表达式, 仅 fork 1 次; PID/CPU 已由 case 校验为纯数字, 无注入风险
  SEDEXPR=''
  for pair in $TOPMAP; do
    PID=${pair%%:*}
    CPU=${pair##*:}
    case "$PID" in ''|*[!0-9]*) continue;; esac
    case "$CPU" in ''|*[!0-9.]*) continue;; esac
    SEDEXPR="$SEDEXPR -e s|\"pid\":$PID,\"name\"|\"pid\":$PID,\"cpu_pct\":$CPU,\"name\"|"
  done
  [ -n "$SEDEXPR" ] || return 0
  DATA=$(printf '%s' "$DATA" | sed $SEDEXPR 2>/dev/null)
  # v3.2.98 F2: CPU Top 进程段 - processes 按 rss 排序, 高CPU低内存进程 (surfaceflinger
  # 17%CPU/56MB) 在 60 条截断外, AI 看不到卡顿元凶. 用已采集的 $RAW 建 cpu_procs top8
  # 跳过 0% idle, 按CPU降序, 去重; 纯数字/字母下划线外的包名 sanitize 掉防注入
  _CPTOP=$(printf '%s\n' "$RAW" | sed -n "$((HDR+1)),\$p" | awk -v c="$CPUCOL" '
    {
      pid = $1; cpu = $c
      name = ""
      for (i = c + 3; i <= NF; i++) { if (i > c + 3) name = name " "; name = name $i }
      if (cpu + 0 <= 0.5) next
      if (seen[name]++) next
      gsub(/[^A-Za-z0-9._-]/, "", name)
      if (name == "") next
      printf "%s:%s:%.1f\n", name, pid, cpu + 0
    }' 2>/dev/null | sort -t: -k3 -rn | head -8)
  if [ -n "$_CPTOP" ]; then
    # v3.2.98: awk 直接输出 JSON 片段 (while 子 shell 内赋值会丢失, 不用中转)
    _CPJ=$(printf '%s\n' "$_CPTOP" | awk -F: '
      {
        gsub(/[\r\n]/, "")
        if ($1 == "") next
        if (NR > 1) printf ","
        printf "{\"name\":\"%s\",\"pid\":%s,\"cpu\":%s}", $1, $2, $3
      }' 2>/dev/null)
    if [ -n "$_CPJ" ]; then
      case "$DATA" in
        *'}') DATA="${DATA%?},\"cpu_procs\":[${_CPJ}]}" ;;
      esac
    fi
  fi
}
inject_cpu_pipe() {
  DATA=$(cat)
  inject_cpu
  printf '%s' "$DATA"
}

# v3.2.92: 注入错误级日志 — C 采集器 logcat 写死为空 (无 NDK 重编译), shell 层补
# 优先 *:E 最近 100 条, 空时回退最近 30 条任意级别 (原 shell 采集也只有 t 20)
# v3.2.97: logcat 转义根治 - 旧实现先构造 JSON 再统一转义, 分隔引号被连带转义成 \"
# 产生 {\"tag\":\"...\"} 非法 JSON, 约 4% 采样被丢弃 (ERROR 采集非 JSON)
# 正确做法: 先转义行内反斜杠和引号, 再做格式提取, \1\2 拿到的已是合法 JSON 片段
# v3.2.97: logcat 转义根治 - 旧实现先构造 JSON 再统一转义, 分隔引号被连带转义成 \"
# 产生 {\"tag\":\"...\"} 非法 JSON, 约 4% 采样被丢弃 (ERROR 采集非 JSON)
# 正确做法: awk gsub 先转义行内反斜杠和引号, 再用 substr 提取字段, 输出即合法 JSON
# (sed 的 s/\\/\\\\/g 遇奇数个反斜杠时末尾漏转义, awk gsub 无此问题)
# v3.2.97: logcat 转义根治 - 旧实现先构造 JSON 再统一转义, 分隔引号被连带转义成 \"
# 产生 {\"tag\":\"...\"} 非法 JSON, 约 4% 采样被丢弃 (ERROR 采集非 JSON)
# 正确做法: awk 先 gsub 转义行内反斜杠和引号, 再 substr 提取字段, 输出即合法 JSON
# POSIX awk 替换串中 \\\\ 才能输出一个 \\ (\\ 会被解释成 \\), 详见 v3.2.97 单元测试
# v3.2.97: logcat 转义根治 - 旧实现先构造 JSON 再统一转义, 分隔引号被连带转义
# 产生 {\"tag\":\"...\"} 非法 JSON, 约 4% 采样被丢弃 (ERROR 采集非 JSON)
# 正确做法: awk 先 gsub 转义行内反斜杠和引号, 再 substr 提取字段, 输出即合法 JSON
# v3.2.97: logcat 转义根治 + 字段缺失防御
# 旧实现两个 bug:
# 1) 先构造 JSON 再统一转义, 分隔引号被连带转义成 \\", 产生非法 JSON
# 2) DATA 不含 "logcat" 字段时 PRE/POST 切割返回原串, 拼出彻底损坏的 JSON
#    (C 采集器 logcat 写死为空数组, 但异常输出/回退 collect.sh 时可能缺字段)
# 修复: awk 先 gsub 转义再提取; PRE/POST 切割前 case 校验 DATA 确有 logcat 字段
inject_logcat() {
  LOGRAW=$(logcat -d -t 100 *:E 2>/dev/null)
  [ -n "$LOGRAW" ] || LOGRAW=$(logcat -d -t 30 2>/dev/null)
  [ -n "$LOGRAW" ] || return 0
  LOGJSON=$(printf '%s\n' "$LOGRAW" | awk '
    {
      gsub(/\\/, "\\\\\\\\"); gsub(/"/, "\\\"")
      # v3.3.1: 跳过含 | 的日志行 — | 在 shell 层会截断 sed 命令 (脚本/管道内容, 日志价值低)
      index($0, "|") && next
      if (match($0, /^[0-9-]+ [0-9:.]+ +[0-9]+ +[0-9]+ +[A-Z] [^:]*:/)) {
        head = substr($0, 1, RLENGTH)
        msg = substr($0, RLENGTH + 1)
        sub(/: *$/, "", head)
        sub(/^ +/, "", msg)
        tag = head
        sub(/^[0-9-]+ [0-9:.]+ +[0-9]+ +[0-9]+ +[A-Z] +/, "", tag)
        printf "{\"tag\":\"%s\",\"msg\":\"%s\"},\n", tag, msg
      }
    }' 2>/dev/null)
  [ -n "$LOGJSON" ] || return 0
  # v3.2.97: 去掉尾部逗号与换行; trim 后再判空 (全换行视为空)
  LOGJSON=$(printf '%s' "$LOGJSON" | tr -d '\n\r\t ' 2>/dev/null)
  LOGJSON=${LOGJSON%,}
  [ -n "$LOGJSON" ] || return 0
  # v3.2.97: 前置校验 - DATA 必须确有 logcat 字段, 否则不动 DATA (旧实现会拼坏)
  case "$DATA" in
    *\"logcat\":*) ;;
    *) return 0 ;;
  esac
  # v3.2.98: 只替换 "logcat":[...] 值段本身 (PRE/POST 重拼会因 msg 内嵌 ] 出错)
  DATA=$(printf '%s' "$DATA" | sed "s|\"logcat\":\[[^]]*\]|\"logcat\":[$LOGJSON]|" 2>/dev/null)
  # v3.3.1: sed 替换失败时保留原 DATA, 绝不用空 PRE/POST 拼出残缺 JSON
}

# v3.2.97: 内核压力/交换/调度器/内核 OOM 日志 - 只读采集, 拼紧凑 JSON
# AI 判断"要不要清内存"不靠 mem% (占得多不代表真的卡), PSI 阻塞率才是"该清"的信号
# 所有读取失败时整个 kernel 字段不注入, 不影响原有 JSON 结构
KGOV_CACHE=''
KOOM_TICK=0
KOOM_CACHE=''
inject_kernel() {
  KJ=''
  # ---- PSI 内存压力 (/proc/pressure/memory) ----
  if [ -r /proc/pressure/memory ]; then
    KJ="$KJ$(awk '
      /^some/ { for (i = 2; i <= NF; i++) { split($i, kv, "=")
        if (kv[1] == "avg10") s10 = kv[2]; if (kv[1] == "avg300") s300 = kv[2]; if (kv[1] == "total") st = kv[2] } }
      /^full/ { for (i = 2; i <= NF; i++) { split($i, kv, "=")
        if (kv[1] == "avg10") f10 = kv[2]; if (kv[1] == "total") ft = kv[2] } }
      END { printf ",\"psi\":{\"s10\":%s,\"s300\":%s,\"st\":%s,\"f10\":%s,\"ft\":%s}", s10+0, s300+0, st+0, f10+0, ft+0 }
    ' /proc/pressure/memory 2>/dev/null)"
  fi
  # ---- zram/swap 使用率 (/proc/meminfo) ----
  KJ="$KJ$(awk '/^SwapTotal:/{t=$2}/^SwapFree:/{f=$2}END{
    if (t > 0) { u = t - f; printf ",\"swap\":{\"total_mb\":%d,\"used_mb\":%d,\"pct\":%d}", t/1024, u/1024, u*100/t }
  }' /proc/meminfo 2>/dev/null)"
  # ---- CPU 调度器与频率 (启动时读一次, 极少变化) ----
  if [ -z "$KGOV_CACHE" ]; then
    _G=$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null)
    _C=$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_cur_freq 2>/dev/null)
    _X=$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_max_freq 2>/dev/null)
    [ -n "$_G" ] && KGOV_CACHE="$_G|$_C|$_X"
  fi
  [ -n "$KGOV_CACHE" ] && KJ="$KJ,\"gov\":\"$KGOV_CACHE\""
  # v3.3.4: 多集群 CPU 频率 (大中小核各自当前频率, 通用: 有几个 cpuN/cpufreq 就报几个)
  if [ -z "$KCLUSTER_CACHE" ]; then
    KCLUSTER_CACHE=""
    for _ci in 0 1 2 3 4 5 6 7; do
      _cf="/sys/devices/system/cpu/cpu$_ci/cpufreq/scaling_cur_freq"
      [ -r "$_cf" ] || continue
      _cv=$(cat "$_cf" 2>/dev/null)
      [ -n "$_cv" ] && KCLUSTER_CACHE="$KCLUSTER_CACHE$_ci:$_cv;"
    done
  fi
  [ -n "$KCLUSTER_CACHE" ] && KJ="$KJ,\"cpu_clusters\":\"$KCLUSTER_CACHE\""
  # v3.3.4: SoC 型号 (getprop ro.soc.model / ro.board.platform, 通用)
  if [ -z "$KSOC_CACHE" ]; then
    _soc=$(getprop ro.soc.model 2>/dev/null)
    [ -z "$_soc" ] && _soc=$(getprop ro.board.platform 2>/dev/null)
    [ -n "$_soc" ] && KSOC_CACHE=$_soc
  fi
  [ -n "$KSOC_CACHE" ] && KJ="$KJ,\"soc\":\"$KSOC_CACHE\""
  # v3.3.4: GPU 时钟与负载 (Adreno kgsl 路径, 无则跳过 — 联发科/三星平台字段缺失不影响)
  if [ -z "$KGPU_CACHE" ]; then
    # v3.3.5: GPU 多平台探测 (高通 Adreno / 联发科 Mali / 三星 / 通用 devfreq)
    _gclk=$(cat /sys/class/kgsl/kgsl-3d0/clock_mhz 2>/dev/null)
    [ -z "$_gclk" ] && _gclk=$(cat /sys/class/kgsl/kgsl-3d0/gpuclk 2>/dev/null)
    [ -z "$_gclk" ] && _gclk=$(cat /sys/kernel/gpu/gpu_clock 2>/dev/null)
    if [ -z "$_gclk" ]; then
      # v3.3.5: 联发科 Mali device 路径 (Hz → MHz)
      _mhz=$(cat /sys/class/misc/mali0/device/clock 2>/dev/null | tr -dc '0-9')
      [ -z "$_mhz" ] && _mhz=$(cat /sys/class/misc/mali0/device/freq 2>/dev/null | tr -dc '0-9')
      if [ -n "$_mhz" ] && [ "$_mhz" -gt 100000 ]; then
        _gclk=$((_mhz / 1000000))
      fi
    fi
    if [ -z "$_gclk" ]; then
      # v3.3.5: 通用 devfreq (mali/g3d/gpu 节点, Hz → MHz)
      for _gd in /sys/class/devfreq/*mali* /sys/class/devfreq/*g3d* /sys/class/devfreq/*gpu*; do
        [ -r "$_gd/cur_freq" ] || continue
        _hz=$(cat "$_gd/cur_freq" 2>/dev/null | tr -dc '0-9')
        if [ -n "$_hz" ] && [ "$_hz" -gt 100000 ]; then
          _gclk=$((_hz / 1000000))
          break
        fi
      done
    fi
    _gbusy=$(cat /sys/class/kgsl/kgsl-3d0/gpu_busy_percentage 2>/dev/null | tr -dc '0-9')
    [ -z "$_gbusy" ] && _gbusy=$(cat /sys/class/misc/mali0/device/gpu_utilisation 2>/dev/null | tr -dc '0-9')
    [ -z "$_gbusy" ] && _gbusy=$(cat /sys/kernel/gpu/gpu_busy 2>/dev/null | tr -dc '0-9')
    [ -n "$_gclk" ] && KGPU_CACHE="$_gclk|$_gbusy"
  fi
  [ -n "$KGPU_CACHE" ] && KJ="$KJ,\"gpu\":\"$KGPU_CACHE\""
  # ---- 内核 OOM/低内存 kill 记录 (dmesg, 每 ~60s 读一次避免开销) ----
  KOOM_TICK=$((KOOM_TICK + 1))
  if [ "$KOOM_TICK" -ge 15 ]; then
    KOOM_TICK=0
    _O=$(dmesg 2>/dev/null | grep -aiE 'oom kill|lowmemory|killed process' | tail -3 | cut -c1-90 | tr -d '\\"' 2>/dev/null)
    KOOM_CACHE=''
    if [ -n "$_O" ]; then
      _O=$(printf '%s' "$_O" | tr '\n' ';' 2>/dev/null)
      KOOM_CACHE="$_O"
    fi
  fi
  [ -n "$KOOM_CACHE" ] && KJ="$KJ,\"oom\":\"$KOOM_CACHE\""
  # ---- ANR traces 文件 (存在则报上次写入时间) ----
  if [ -r /data/anr/traces.txt ]; then
    _AM=$(stat -c '%Y' /data/anr/traces.txt 2>/dev/null)
    if [ -n "$_AM" ]; then
      _AGE=$(( $(date +%s) - _AM ))
      KJ="$KJ,\"anr_age_s\":$_AGE"
    fi
  fi

  # v3.4.23: IO 压力 (/proc/pressure/io) — 卡顿与该清缓存的直接判据
  if [ -r /proc/pressure/io ]; then
    KJ="$KJ$(awk '
      /^some/ { for (i = 2; i <= NF; i++) { split($i, kv, "=")
        if (kv[1] == "avg10") is10 = kv[2]; if (kv[1] == "avg300") is300 = kv[2] } }
      /^full/ { for (i = 2; i <= NF; i++) { split($i, kv, "=")
        if (kv[1] == "avg10") if10 = kv[2] } }
      END { printf ",\"psi_io\":{\"s10\":%s,\"s300\":%s,\"f10\":%s}", is10+0, is300+0, if10+0 }
    ' /proc/pressure/io 2>/dev/null)"
  fi
  # v3.4.23: CPU 压力 (/proc/pressure/cpu) — some=任务在等 CPU, full=所有核都忙
  if [ -r /proc/pressure/cpu ]; then
    KJ="$KJ$(awk '
      /^some/ { for (i = 2; i <= NF; i++) { split($i, kv, "=")
        if (kv[1] == "avg10") cs10 = kv[2]; if (kv[1] == "avg300") cs300 = kv[2] } }
      END { printf ",\"psi_cpu\":{\"s10\":%s,\"s300\":%s}", cs10+0, cs300+0 }
    ' /proc/pressure/cpu 2>/dev/null)"
  fi
  # v3.4.23: 系统负载 (/proc/loadavg) — 1/5/15 分钟均值与运行队列
  if [ -r /proc/loadavg ]; then
    KJ="$KJ$(awk '{ load1=$1; load5=$2; load15=$3; split($4, rq, "/");
      printf ",\"loadavg\":{\"m1\":%s,\"m5\":%s,\"m15\":%s,\"running\":%s,\"total\":%s}", load1, load5, load15, rq[1], rq[2] }' /proc/loadavg 2>/dev/null)"
  fi
  # ---- 拼接到 JSON 尾部 (替换最后的 "}") ----
  if [ -n "$KJ" ]; then
    KJ=${KJ#,}
    case "$DATA" in
      *'}') DATA="${DATA%?},\"kernel\":{$KJ}}" ;;
    esac
  fi
}
norm_storage() {
  printf '%s' "$1" | sed 's|"mount":"/data"|"mount":"/storage/emulated"|'
}
while true; do
  SAMPLES=$((SAMPLES + 1))
  if [ "$USE_C" = "1" ]; then
    DATA=$("$CBIN" 2>/dev/null)
    # v3.2.35: C 采集器无 modules 字段, shell 扫描补充 (带缓存)
    # v3.2.35: norm_storage 统一 C 采集器 storage 显示名, 再注入 modules
    [ -n "$DATA" ] && DATA=$(norm_storage "$DATA" | inject_mods)
    inject_cpu
    inject_logcat
    inject_kernel
    inject_wl
    inject_du
    inject_power
    inject_labels
    # v3.4.22: 媒体播放状态注入 (AI payload 用, 知道谁在放音乐)
    inject_media
    # v3.4.25: 电池增强注入 (SoH/循环次数/充电功率/型号, BE_TICK=30 周期缓存)
    inject_batt_ext
    # v3.4.25: 每应用流量排行 (dumpsys netstats, NS_TICK=60 周期缓存)
    inject_net_stats
    # v3.4.32: 屏幕状态 (SC_TICK=5), 通知计数 (NT_TICK=30), 崩溃记录 (DB_TICK=120)
    inject_screen
    inject_notif
    inject_crashes
    # v3.4.32: 系统安全防护 (SEC_TICK=30, 与通知同频; 威胁面: 设备管理器/辅助服务/通知监听/锁屏凭据/新增包)
    inject_security
    # v3.4.20: 应用名标签缓存 (耗电排行详情用), 每 300 采样周期刷一次 (~15分钟), 低频不当家
    LB_TICK=$((LB_TICK + 1))
    if [ "$LB_TICK" -ge 300 ]; then
      LB_TICK=0
      sh "$DIR/pkg_label.sh" >/dev/null 2>&1 &
    fi
  else
    DATA=$(sh "$DIR/collect.sh" 2>/dev/null)
    # v3.2.92: shell 回退分支也补注入 — C 采集器偶发无输出回退时, cpu_pct/logcat 不能丢
if [ -n "$DATA" ]; then
      inject_cpu
      inject_logcat
      inject_kernel
      inject_wl
      inject_du
      inject_power
      inject_labels
      inject_media
    fi
  fi
  if [ -z "$DATA" ] && [ "$USE_C" = "1" ]; then
    plog 'WARN C 采集器无输出, 回退 shell'
    USE_C=0
    C_RETRY_AT=$((SAMPLES + 900))   # v3.2.34: 偶发失败后 ~1 小时重试 C 采集器
  fi
  # v3.2.34: 周期性重试 C 采集器 (原实现一旦回退就永久使用慢速 shell)
  if [ "$USE_C" = "0" ] && [ -n "$CBIN" ] && [ "$SAMPLES" -ge "$C_RETRY_AT" ]; then
    PROBE=$("$CBIN" 2>/dev/null | awk '{printf "%s", substr($0,1,1); exit}')
    if [ "$PROBE" = "{" ]; then USE_C=1; plog 'INFO C 采集器恢复'; fi
    C_RETRY_AT=$((SAMPLES + 900))
  fi
  if [ -n "$DATA" ]; then
    # v3.2.34: 非法 JSON (空字段) 视为无效, 不覆盖状态文件
    # v3.2.97: 精确空字段检测 - 旧规则 *':,'* 会把 logcat msg 里的 ':,' ':}' 文本
    # 误判为非法 JSON, 约 4% 采样被错杀 (AI 服务把脚本内容打印到 logcat 时必现)
    # 真正的空字段是键值位置: "key":, 或 "key":} — 用 grep -qE 精确匹配
    if printf '%s' "$DATA" | grep -qE '"[^"]*":\s*([,}]|$)' 2>/dev/null; then
      DATA=''
    fi
    [ -n "$DATA" ] || plog 'WARN 采集含空字段, 已丢弃'
    _O=$(printf '%s' "$DATA" | tr -cd '{' | wc -c)
    _C=$(printf '%s' "$DATA" | tr -cd '}' | wc -c)
    if [ "$_O" != "$_C" ]; then
      plog "WARN 括号不平衡 open=$_O close=$_C, 已丢弃"
      DATA=''
    fi
    case "$DATA" in
      '{'*'}'*)
        printf '%s\n' "$DATA" > "$OUT.new" 2>/dev/null
        if [ -s "$OUT.new" ]; then
          chmod 644 "$OUT.new" 2>/dev/null
          mv "$OUT.new" "$OUT" 2>/dev/null
        else
          rm -f "$OUT.new" 2>/dev/null
        fi
        DLEN=$(printf '%s' "$DATA" | wc -c)
        plog "INFO 采样 OK ($DLEN 字节)"
        # v3.2.34: 历史落盘
        COUNT=$((COUNT + 1))
        if [ "$COUNT" -ge "$HIST_EVERY" ]; then
          COUNT=0
          LINE=$(hist_extract "$DATA")
          if [ -n "$LINE" ]; then
            printf '%s\n' "$LINE" >> "$HIST" 2>/dev/null
            chmod 644 "$HIST" 2>/dev/null
            # v3.2.94: 同步镜像到 WebView 可读路径 (落盘时追加, 不用每秒复制整文件)
            printf '%s\n' "$LINE" >> "$HIST_MIRROR" 2>/dev/null
            chmod 644 "$HIST_MIRROR" 2>/dev/null
            # 每 60 次落盘检查一次轮转 (约 12 分钟)
            ROTATE_TICK=$((ROTATE_TICK + 1))
            [ "$ROTATE_TICK" -ge 60 ] && { ROTATE_TICK=0; hist_rotate; }
          fi
        fi
        ;;
      *)
        # 采集结果非 JSON (collect.sh 异常), 清理残留并保留旧数据
        DHEAD=$(printf '%s' "$DATA" | head -c 80)
        plog "ERROR 采集非 JSON: $DHEAD"
        rm -f "$OUT.new" 2>/dev/null
        ;;
    esac
  else
    plog 'ERROR 采集为空'
    rm -f "$OUT.new" 2>/dev/null
  fi
  # v3.2.36: 每 15 次采样 (~60s) 检测白名单变化, 息屏时跳过
  ICON_TICK=$((ICON_TICK + 1))
  if [ "$ICON_TICK" -ge 15 ] && ! is_screen_off; then
    ICON_TICK=0
    refresh_icons
  fi

  # v3.1.9: 息屏降频
  if is_screen_off; then
    sleep "$IDLE_INTERVAL"
  else
    sleep "$INTERVAL"
  fi
done