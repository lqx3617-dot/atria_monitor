#!/system/bin/sh
# Atria Monitor v3.4.89 - 状态采集
# v3.1.9 修复 (相对 v3.1.8):
#   1) JSON 转义重写为逐字符判定: 反斜杠正确加倍, 引号转义, 控制字符转义或剔除
#      (v3.1.8 的 gsub(/\\/, "\\", s) 是空操作 -> 含 \ 的日志行直接破坏整个 JSON)
#   2) 转义判定不再用 [^[:print:]], UTF-8 中文不会被误删; CRLF 行尾用 sub(/\r$/,"") 显式去除
#   3) disable 探测路径补斜杠 (v3.1.8 查的是 .../modAdisable, 启用状态恒为 true)
#   4) 无 module.prop 的目录拼接改为逗号前缀, 修复双逗号
#   5) device_id 经 json_esc 转义; MEM 字段数字守卫; CPU 逐字段求和兼容缺失字段
#   6) su 分支的 awk 程序经 base64 传入 root shell, 不再写入世界可写目录后以 root 执行
# 说明: AWKPROG 内含 $ 与引号, 只能经 "$AWKPROG" 直接传给本shell的 awk, 或编解码后传 su.

DEV="${DEVICE_ID:-$(getprop ro.product.model 2>/dev/null)}"
[ -z "$DEV" ] && DEV="android"

# v3.2.34: 合并为一次 awk, 结果 "total avail" 用参数展开拆开 (省一次 awk fork)
MEM_BOTH=$(awk '/MemTotal|MemAvailable/{if($1=="MemTotal:")t=int($2/1024);else if($1=="MemAvailable:")a=int($2/1024)}END{print t" "a}' /proc/meminfo 2>/dev/null)
MEM_TOTAL=${MEM_BOTH%% *}
MEM_AVAIL=${MEM_BOTH##* }
case "$MEM_TOTAL" in ''|*[!0-9]*) MEM_TOTAL=0;; esac
case "$MEM_AVAIL" in ''|*[!0-9]*) MEM_AVAIL=0;; esac
MEM_USED=$((MEM_TOTAL - MEM_AVAIL))
if [ "$MEM_TOTAL" -gt 0 ] && [ "$MEM_USED" -ge 0 ]; then
  MEM_PCT=$((MEM_USED * 100 / MEM_TOTAL))
else
  MEM_PCT=0; MEM_USED=0
fi

# ---- awk 公共程序: 转义 + logcat/ps/模块解析 (无单引号, 可安全编解码传输) ----
AWKPROG='function JESC(s,   r, c, k, dirty) {
  for (k = 1; k <= length(s); k++) {
    c = substr(s, k, 1)
    if (c == BS || c == Q || c < SP) { dirty = 1; break }
  }
  if (!dirty) return s
  r = ""
  for (k = 1; k <= length(s); k++) {
    c = substr(s, k, 1)
    if (c == BS) r = r BS BS
    else if (c == Q) r = r BS Q
    else if (c == NL) r = r BS "n"
    else if (c == CR) r = r BS "r"
    else if (c == TAB) r = r BS "t"
    else if (c < SP) continue
    else r = r c
  }
  return r
}
# v3.2.34: 输出加 id 字段 (模块目录名, 供面板的启用/禁用开关定位)
function emit_mod() {
  printf "%s", "{" Q "name" Q ":" Q JESC(MODNAME) Q "," Q "id" Q ":" Q JESC(mod) Q "," Q "enabled" Q ":" ENABLED "},"
}
# (保留旧实现以备回退; printf 多参数拼接格式串易错, 改为字符串拼接后单参数输出)
BEGIN {
  BS = sprintf("%c", 92); Q = sprintf("%c", 34); SP = sprintf("%c", 32)
  NL = sprintf("%c", 10); CR = sprintf("%c", 13); TAB = sprintf("%c", 9)
}
# v3.2.34: all 相位 - 一次调用处理全部数据源, FILENAME 前缀决定 section
phase == "all" {
  # /tmp/.../01_thermal -> thermal
  sec = FILENAME; sub(/.*\/[0-9]+_/, "", sec)
  if      (sec == "thermal") handle_thermal()
  else if (sec == "battery") handle_battery()
  else if (sec == "storage") handle_storage()
  else if (sec == "net")     handle_net()
  else if (sec == "ps")      handle_ps()
  else if (sec == "logcat")  handle_logcat()
  else if (sec == "mods")    handle_mods()
  else if (sec == "noprop")  handle_noprop()
  next
}
# v3.2.34: thermal 直读 sysfs (shell 不再逐 zone cat, 减少 82 次 fork)
# FILENAME = .../thermal_zoneN/temp; 同目录 type 文件 getline 取类别
phase == "thermal" && FNR == 1 {
  zdir = FILENAME; sub(/\/temp$/, "", zdir)
  typ = "zone"
  if ((getline ln < (zdir "/type")) > 0 && ln != "") typ = ln
  close(zdir "/type")
  t = $0 + 0
  if (t > 0) print typ, FILENAME, t
  next
}
phase == "thermal" && FNR > 1 { next }

# v3.2.34: 按类别聚合 (cpu/gpu/modem/...), 同类 zone 只输出 max/min/count
# 输入: $1=类别(来自 type 文件) $2=zone路径 $3=温度(millicelsius)
function handle_thermal(  typ, t, grp) {
  typ = $1
  t = $3 + 0
  if (t <= 0) return
  grp = typ
  # v3.2.34: cpu 归类大小写不敏感 + 常见内核名称 (soc/apc/xo 等)
  if (grp ~ /^[cC][pP][uU]/ || grp ~ /^(silver|gold|prime|bronze|big|little|core)/ || grp ~ /^soc/ || grp ~ /^apc/ || grp ~ /^denve/) grp = "cpu"
  else if (grp ~ /^gpu/ || grp ~ /[gG][pP][uU]/) grp = "gpu"
  else if (grp ~ /modem/ || grp ~ /mdm/) grp = "modem"
  else if (grp ~ /skin/ || grp ~ /surface/ || grp ~ /^xd$|^xo-/) grp = "skin"
  else if (grp ~ /batt/ || grp ~ /[bB]attery/) grp = "batt"
  else if (grp ~ /charge|usb|^pa_/) grp = "charger"
  else if (grp ~ /wifi|wlan/) grp = "wifi"
  else if (grp ~ /dsp|nsp|adsp/) grp = "dsp"
  # v3.3.4: 高通平台新增类 — video/ddr 归 other 细分, aoss/cpuss 归 cpu (SoC 子系统),
  # shell_* 归 skin (外壳温度), camera 类独立 (主板热区不影响机身体感)
  else if (grp ~ /^aoss|^cpuss|^socd/) grp = "cpu"
  else if (grp ~ /^shell_|^shell-/) grp = "skin"
  else if (grp ~ /^camera|^cam-/) grp = "camera"
  else if (grp ~ /^video|^ddr/) grp = "chipset"
  else grp = "other"
  if (!(grp in TMAX) || t > TMAX[grp]) TMAX[grp] = t
  if (!(grp in TMIN) || t < TMIN[grp]) TMIN[grp] = t
  TCNT[grp]++
}
# v3.2.34: END 时输出聚合结果 (每类一条记录)
function thermal_flush(  g) {
  for (g in TMAX) {
    if (TCNT[g] > 0) {
      rec = Q "label" Q ":" Q g Q "," Q "temp" Q ":" (TMAX[g] / 1000) "," Q "min" Q ":" (TMIN[g] / 1000) "," Q "count" Q ":" TCNT[g]
      printf "THERMAL:{%s},\n", rec
    }
  }
}
# v3.2.34: 电池 (uevent KEY=VALUE, END 时汇总)
function handle_battery() {
  eq = index($0, "=")
  if (eq > 0) {
    k = substr($0, 1, eq - 1); v = substr($0, eq + 1)
    if (k == "POWER_SUPPLY_CAPACITY") bcap = v + 0
    else if (k == "POWER_SUPPLY_STATUS") bst = v
    else if (k == "POWER_SUPPLY_CURRENT_NOW") bcur = v + 0
    else if (k == "POWER_SUPPLY_VOLTAGE_NOW") bvol = v + 0
    else if (k == "POWER_SUPPLY_HEALTH") bhlth = v
    else if (k == "POWER_SUPPLY_TEMP") btemp = (v + 0) / 10
  }
}
# v3.2.34: 存储 (df 输出)
function handle_storage(  total, used, free, pct, mnt) {
  # v3.2.35: 只保留用户实际使用的存储分区, 并统一显示名 + 去重
  # - "/" 是只读 system 分区 (dm-verity), 恒 100% 且不可清理, 显示它只会误导用户
  # - /data 被 tmpfs 遮挡 (df 落到 /data/misc/profiles/...), 不是真实用户存储
  # - root 命名空间下 fuse 挂载点是 /mnt/installer/0/emulated 与 /mnt/pass_through/0/emulated,
  #   用户命名空间里才是 /storage/emulated; 三者是同一物理分区, 只报告一次并统一显示名
  if ($1 ~ /^tmpfs|^overlay|^(none|proc|sysfs|devpts|cgroup|debugfs)$|^\/dev\/block\/loop/ && NF >= 6) return
  if (NF < 6) return
  total = $2 / 1048576; used = $3 / 1048576; free = $4 / 1048576; pct = ($2 > 0) ? int($3 * 100 / $2) : 0
  mnt = $6
  for (i = 7; i <= NF; i++) mnt = mnt " " $i
  # v3.2.35: 匹配用户存储的各命名空间视图, 统一显示名
  is_user_store = 0
  if (mnt == "/storage/emulated" || mnt == "/sdcard") is_user_store = 1
  else if (mnt ~ /^\/mnt\/(installer|pass_through)\/[0-9]+\/emulated$/) is_user_store = 1
  # v3.2.35: 去重 - 同一分区在多个命名空间视图下重复出现, 只输出第一次
  if (total >= 0.5 && is_user_store && !STOR_EMITTED) {
    STOR_EMITTED = 1
    mnt = "/storage/emulated"   # 统一显示名, 避免重复/暴露内部挂载路径
    rec = Q "mount" Q ":" Q mnt Q "," Q "total_gb" Q ":" total "," Q "used_gb" Q ":" used "," Q "free_gb" Q ":" free "," Q "percent" Q ":" pct
    printf "STORAGE:{%s},\n", rec
  }
}
# v3.2.34: 网络设备
function handle_net(  dev) {
  if ($1 ~ /^wlan|^rmnet|^eth|^usb/) {
    dev = $1; sub(/:/, "", dev)
    if (NF >= 10) {
      rec = Q "dev" Q ":" Q dev Q "," Q "rx_bytes" Q ":" ($2 + 0) "," Q "tx_bytes" Q ":" ($10 + 0)
      printf "NET:{%s},\n", rec
    }
  }
}
# v3.2.34: 进程 (ps 输出, 暂存数组 END 排序)
function handle_ps(  pid, rss, st, name, i) {
  if (NF < 4 || $1 !~ /^[0-9]+$/ || $2 !~ /^[0-9]+$/) return
  if (($2 + 0) <= 10240) return
  pid = $1 + 0; rss = $2 + 0; st = substr($3, 1, 1)
  name = ""
  for (i = 4; i <= NF; i++) name = name (i > 4 ? " " : "") $i
  pcnt++; P[pcnt] = pid; R[pcnt] = rss; S[pcnt] = st; N[pcnt] = name
}
# v3.2.34: logcat
function handle_logcat(  rest, tag, msg, i) {
  if (NF < 6 || $0 ~ /^---/) return
  rest = ""
  for (i = 6; i <= NF; i++) rest = rest (i > 6 ? " " : "") $i
  if (rest ~ /:/) { tag = substr(rest, 1, index(rest, ":") - 1); msg = substr(rest, index(rest, ":") + 1) }
  else { tag = "unknown"; msg = rest }
  rec = Q "tag" Q ":" Q JESC(tag) Q "," Q "msg" Q ":" Q JESC(msg) Q
  printf "LOG:{%s},\n", rec
}
# v3.2.34: 模块 (每行一个 module.prop 路径)
function handle_mods(  f, d, n, p, dis, line, en, name, i) {
  f = $0
  if ((getline line < f) <= 0) { close(f); return }
  close(f)
  # 逐行读 module.prop 找 name=
  name = ""
  while ((getline line < f) > 0) {
    if (line ~ /^name=/) { sub(/^name=/, "", line); sub(/\r$/, "", line); name = line }
  }
  close(f)
  i = index(f, "/module.prop")
  if (i < 1) return
  d = substr(f, 1, i - 1)
  n = split(d, p, "/")
  en = "true"
  dis = d "/disable"
  if ((getline line < dis) >= 0) en = "false"
  close(dis)
  if (length(name) == 0) name = p[n]
  # v3.2.34: id = 模块目录名, 供面板启用/禁用开关定位
  mid = p[n]
  rec = Q "name" Q ":" Q JESC(name) Q "," Q "id" Q ":" Q JESC(mid) Q "," Q "enabled" Q ":" en
  printf "MOD:{%s},\n", rec
}
# v3.2.34: 无 module.prop 的目录 (shell 写入 "目录名 true/false")
# v3.2.34: 无 prop 目录的 id 就是目录名本身
function handle_noprop(  en) {
  if (NF < 2) return
  en = $2
  rec = Q "name" Q ":" Q JESC($1) Q "," Q "id" Q ":" Q JESC($1) Q "," Q "enabled" Q ":" en
  printf "MOD:{%s},\n", rec
}
phase == "esc" { printf "%s", JESC($0); exit }
# v3.2.34: 温度 (thermal_zone) - 输出 {"label":"cpu","temp":45.0}
# v3.2.34: FILENAME 含完整路径, 从中提取 zone 编号
phase == "thermal" {
  z = FILENAME; sub(/.*thermal_zone/, "zone", z); sub(/\/temp.*/, "", z)
  t = $1 + 0
  if (t > 0) printf "%s", "{" Q "label" Q ":" Q z Q "," Q "temp" Q ":" (t / 1000) "},"
}
# v3.2.34: 电池 uevent - 输出 {"capacity":85,"status":"Charging","current_ua":500000,"voltage_uv":4200000,"health":"Good","temperature":35.5}
phase == "battery" {
  eq = index($0, "=")
  if (eq > 0) { k = substr($0, 1, eq - 1); v = substr($0, eq + 1) }
  else next
  if (k == "POWER_SUPPLY_CAPACITY") cap = v + 0
  else if (k == "POWER_SUPPLY_STATUS") st = v
  else if (k == "POWER_SUPPLY_CURRENT_NOW") cur = v + 0
  else if (k == "POWER_SUPPLY_VOLTAGE_NOW") vol = v + 0
  else if (k == "POWER_SUPPLY_HEALTH") hlth = v
  else if (k == "POWER_SUPPLY_TEMP") btemp = (v + 0) / 10
}
# v3.2.34: 存储挂载点 - 输出 {"mount":"/data","total_gb":64.0,"used_gb":40.5,"free_gb":23.5,"percent":63}
phase == "storage" {
  # v3.2.35: 复用 handle_storage (与 all 相位一致: 只输出用户存储, 去重, 统一显示名)
  handle_storage()
}
# v3.2.34: 网速 (/proc/net/dev), 输出设备累计字节, 前端差值计算速率
phase == "net" {
  if ($1 ~ /^wlan|^rmnet|^eth|^usb/) {
    dev = $1; sub(/:/, "", dev)
    if (NF >= 10) {
      rx = $2 + 0; tx = $10 + 0
      printf "%s", "{" Q "dev" Q ":" Q dev Q "," Q "rx_bytes" Q ":" rx "," Q "tx_bytes" Q ":" tx "},"
    }
  }
}
# v3.2.34: 电池汇总输出 (整文件解析完后)
# v3.2.34: battery 汇总在文件结束时输出 (END 块按 phase 分发)
phase == "battery" && FNR == 1 { batt_started = 1 }
phase == "logcat" && NF >= 6 && $0 !~ /^---/ {
  rest = ""
  for (i = 6; i <= NF; i++) rest = rest (i > 6 ? " " : "") $i
  if (rest ~ /:/) { tag = substr(rest, 1, index(rest, ":") - 1); msg = substr(rest, index(rest, ":") + 1) }
  else { tag = "unknown"; msg = rest }
  printf "%s", "{" Q "tag" Q ":" Q JESC(tag) Q "," Q "msg" Q ":" Q JESC(msg) Q "},"
}
# v3.2.34: ps -A -o pid,rss,stat,comm - $3 是状态列 (S/R/Z 等), comm 从 $4 起
phase == "ps" && NF >= 4 && $1 ~ /^[0-9]+$/ && $2 ~ /^[0-9]+$/ && ($2 + 0) > 10240 {
  pid = $1 + 0; rss_kb = $2 + 0; stat = $3
  name = ""
  for (i = 4; i <= NF; i++) name = name (i > 4 ? " " : "") $i
  # v3.2.34: 去掉状态后缀里的 + (前台) 和 < (高优先级) 等修饰, 只留主状态字母
  st = substr(stat, 1, 1)
  out = "{" Q "pid" Q ":" pid "," Q "name" Q ":" Q JESC(name) Q "," Q "rss_mb" Q ":" int(rss_kb / 1024) "," Q "stat" Q ":" Q st Q "}"
  # v3.2.34: 暂存到数组, END 时按 rss 排序输出 (top 60, 门槛 10MB)
  cnt++
  P[cnt] = out; R[cnt] = rss_kb
}
# v3.2.34: 排序输出放在主 END 规则里 (END 不能作条件模式)
FNR == 1 && phase == "mods" {
  if (mod != "") emit_mod()
  i = index(FILENAME, "/module.prop")
  if (i < 1) { mod = FILENAME; MODNAME = FILENAME; ENABLED = "true"; next }
  d = substr(FILENAME, 1, i - 1)
  n = split(d, p, "/")
  mod = p[n]
  MODNAME = mod
  ENABLED = "true"
  dis = d "/disable"
  if ((getline line < dis) >= 0) ENABLED = "false"
  close(dis)
}
/^name=/ && phase == "mods" { sub(/^name=/, ""); sub(/\r$/, ""); MODNAME = $0 }
END {
  if (phase == "mods" && mod != "") emit_mod()
  # v3.2.34: 温度聚合输出 (每类一条, 而非每个 zone 一条)
  if (phase == "all" || phase == "thermal") thermal_flush()
  # v3.2.34: all 相位的电池汇总
  if (phase == "all" && (bcap != 0 || bst != "")) {
    rec = Q "capacity" Q ":" (bcap + 0) "," Q "status" Q ":" Q (bst == "" ? "Unknown" : bst) Q "," Q "current_ua" Q ":" (bcur + 0) "," Q "voltage_uv" Q ":" (bvol + 0) "," Q "health" Q ":" Q (bhlth == "" ? "Unknown" : bhlth) Q "," Q "temperature" Q ":" (btemp + 0)
    print "BATTERY:{" rec "}"
  }
  # v3.2.34: all 相位的 ps 排序 (与独立 ps 相位共用数组)
  if (phase == "all") {
    for (i = 2; i <= pcnt; i++) {
      v = R[i]; vo = P[i]; vn = N[i]; vs = S[i]; j = i - 1
      while (j >= 1 && R[j] < v) { R[j+1] = R[j]; P[j+1] = P[j]; N[j+1] = N[j]; S[j+1] = S[j]; j-- }
      R[j+1] = v; P[j+1] = vo; N[j+1] = vn; S[j+1] = vs
    }
    top = (pcnt < 60) ? pcnt : 60
    for (i = 1; i <= top; i++) {
      rec = Q "pid" Q ":" P[i] "," Q "name" Q ":" Q JESC(N[i]) Q "," Q "rss_mb" Q ":" int(R[i] / 1024) "," Q "stat" Q ":" Q S[i] Q
      printf "PROC:{%s},\n", rec
    }
  }
  # v3.2.34: ps 相位 - 按 RSS 降序输出 top 60
  if (phase == "ps" && cnt > 0) {
    for (i = 2; i <= cnt; i++) {
      v = R[i]; vo = P[i]; j = i - 1
      while (j >= 1 && R[j] < v) { R[j + 1] = R[j]; P[j + 1] = P[j]; j-- }
      R[j + 1] = v; P[j + 1] = vo
    }
    top = (cnt < 60) ? cnt : 60
    for (i = 1; i <= top; i++) printf "%s", P[i] ","
  }
  # v3.2.34: 电池汇总输出
  if (phase == "battery" && (cap != 0 || st != "")) {
    rec = Q "capacity" Q ":" (cap + 0) "," Q "status" Q ":" Q (st == "" ? "Unknown" : st) Q "," Q "current_ua" Q ":" (cur + 0) "," Q "voltage_uv" Q ":" (vol + 0) "," Q "health" Q ":" Q (hlth == "" ? "Unknown" : hlth) Q "," Q "temperature" Q ":" (btemp + 0)
    printf "%s", "{" rec "}"
  }
}
'

# v3.2.34: 纯 shell 逐字符转义, 不再为每次转义 fork 一个 awk (原实现 2 次/采样)
# v3.2.34: 控制字符预计算. 注意换行不能用 $() (会被 strip), 用字面嵌入
JSON_TAB=$(printf '\t')
JSON_CR=$(printf '\r')
JSON_NL='
'
json_esc() {
  out=''; rest=$1
  while [ -n "$rest" ]; do
    c=${rest%"${rest#?}"}
    rest=${rest#?}
    case "$c" in
      \\*) out="$out\\\\" ;;
      \") out="$out\\\"" ;;
      "$JSON_TAB") out="$out\\t" ;;
      "$JSON_CR") out="$out\\r" ;;
      "$JSON_NL") out="$out\\n" ;;
      *) out="$out$c" ;;
    esac
  done
  printf '%s' "$out"
}

# ---- CPU: 取 /proc/stat 首行 cpu 汇总, 逐字段求和, 容忍字段缺失 ----
CPUFIRST=''
read -r CPUFIRST < /proc/stat 2>/dev/null || CPUFIRST=''
TOTAL=0; USED=0; CI=0
set -- $CPUFIRST
shift 2>/dev/null || true
for f in "$@"; do
  CI=$((CI + 1))
  case "$f" in ''|*[!0-9]*) continue;; esac
  case "$CI" in 1|2|3|6|7|8) USED=$((USED + f));; esac
  TOTAL=$((TOTAL + f))
done

PREV=/data/local/tmp/atria_cpu_prev
CPU_PCT=0
if [ "$TOTAL" -gt 0 ]; then
  if [ -r "$PREV" ]; then
    read -r PT PU < "$PREV" 2>/dev/null
    case "$PT" in ''|*[!0-9]*) PT=0;; esac
    case "$PU" in ''|*[!0-9]*) PU=0;; esac
    if [ "$PT" -gt 0 ]; then
      DT=$((TOTAL - PT)); DU=$((USED - PU))
      if [ "$DT" -gt 0 ]; then
        [ "$DU" -lt 0 ] && DU=0
        CPU_PCT=$((DU * 100 / DT))
        [ "$CPU_PCT" -gt 100 ] && CPU_PCT=100
      fi
    fi
  fi
  printf '%s %s\n' "$TOTAL" "$USED" > "$PREV" 2>/dev/null
fi

MROOT="${ATRIA_MODROOT:-/data/adb/modules}"

# ---- 模块列表 ----
MODS=''
if [ -n "$(ls "$MROOT" 2>/dev/null)" ]; then
  if [ "$( [ -w / ] && echo 0 || echo 1 )" = "0" ]; then
    # v3.2.34: 先展开通配, 无模块时不传文件参数给 awk (原通配不展开导致 awk fatal)
    MODARGS=""
    for mp in "$MROOT"/*/module.prop; do
      [ -r "$mp" ] && MODARGS="$MODARGS $mp"
    done
    [ -n "$MODARGS" ] && MODS=$(awk -v phase=mods "$AWKPROG" $MODARGS 2>/dev/null)
  else
    # v3.1.9: awk 程序 base64 编码后传给 root shell, 在 root 专属目录解出再执行.
    # 程序与参数均不含未转义的 $ 或引号, 杜绝 v3.1.8 写 /data/local/tmp 的篡改窗口
    B64=$(printf '%s' "$AWKPROG" | base64 2>/dev/null | tr -d '\n ')
    if [ -n "$B64" ]; then
      MODS=$(su -c "printf '%s' '$B64' | base64 -d > /data/adb/atria_mods.awk 2>/dev/null; chmod 600 /data/adb/atria_mods.awk 2>/dev/null; awk -v phase=mods -f /data/adb/atria_mods.awk '$MROOT'/*/module.prop" 2>/dev/null)
    fi
  fi
fi
case "$MODS" in *,) MODS=${MODS%,};; esac
# 无 module.prop 的目录仍展示, 名称回退为目录名
for d in "$MROOT"/*/; do
  [ -d "$d" ] || continue
  [ -r "${d}module.prop" ] && continue
  m=${d%/}; m=${m##*/}
  [ -n "$m" ] || continue
  if [ -e "${d}disable" ]; then EN=false; else EN=true; fi
  [ -n "$MODS" ] && MODS="$MODS,"
  MODS="$MODS{\"name\":\"$(json_esc "$m")\",\"enabled\":$EN}"
done

# ---- v3.2.34: 温度 (多 zone) ----
# v3.2.34: 一次 awk 读全部 zone (原实现每个 zone 一次 cat + printf 管道)
# v3.2.34: 各数据源写入带序号前缀的临时文件, 一次 awk 全部处理
# (原实现 7 次 awk, 每次要重新解析完整程序; 合并后只解析一次)
# v3.2.34: TMPD 创建失败时回退到直接目录 (磁盘满/权限问题曾导致全空 JSON)
# v3.2.34: TMPD 用 PID 唯一化, 防止两轮采集重叠时互相覆盖固定目录
TMPD=/data/local/tmp/atria_tmp_$$
if ! mkdir -p "$TMPD" 2>/dev/null; then
  TMPD=/tmp/atria_tmp_$$
  mkdir -p "$TMPD" 2>/dev/null || TMPD=''
fi
# v3.2.34: thermal 全部交给 awk 一次遍历 (原逐 zone 双 cat = 82 次 fork)
awk -v phase=thermal "$AWKPROG" /sys/class/thermal/thermal_zone*/temp > "$TMPD/01_thermal" 2>/dev/null
BATTF=''
for b in /sys/class/power_supply/battery/uevent /sys/class/power_supply/bms/uevent; do
  [ -r "$b" ] && { BATTF="$b"; break; }
done
# v3.2.34 修复: 强制创建 02_battery, 否则缺失时 awk fatal 中断导致全部指标丢失
: > "$TMPD/02_battery" 2>/dev/null
[ -n "$BATTF" ] && cat "$BATTF" > "$TMPD/02_battery" 2>/dev/null
# v3.2.34: 独立数据源并行采集 (原顺序执行, df+ps+logcat 各 30-70ms 串行约 200ms)
df -k > "$TMPD/03_storage" 2>/dev/null &
cat /proc/net/dev > "$TMPD/04_net" 2>/dev/null &
# v3.2.34: name 列取包名 (toybox name 来自 cmdline=应用包名; comm 对应用进程显示 app_process64)
# 旧版用 comm 导致所有应用都叫 app_process64. procps/无 name 列时回退 comm.
# v3.2.34: 检查表头是否含 NAME 列 (原实现依赖第一行进程恰好是 S 状态, R/Z 时误判)
if ps -A -o pid,rss,stat,name 2>/dev/null | head -1 | grep -q "NAME"; then
  ps -A -o pid,rss,stat,name > "$TMPD/05_ps" 2>/dev/null &
else
  ps -A -o pid,rss,stat,comm > "$TMPD/05_ps" 2>/dev/null &
fi
if [ "$( [ -w / ] && echo 0 || echo 1 )" = "0" ]; then
  # v3.2.92: 日志采集分级 — 错误日志优先 (*:E 最近 100 条), 空时回退最近 30 条
  # 原实现只取最后 20 条任意级别, OOM/ANR 报错常不在窗口内
  (
    logcat -d -t 100 *:E > "$TMPD/06_logcat" 2>/dev/null
    [ -s "$TMPD/06_logcat" ] || logcat -d -t 30 > "$TMPD/06_logcat" 2>/dev/null
  ) &
else
  (
    su -c "logcat -d -t 100 *:E" > "$TMPD/06_logcat" 2>/dev/null
    [ -s "$TMPD/06_logcat" ] || su -c "logcat -d -t 30" > "$TMPD/06_logcat" 2>/dev/null
  ) &
fi
wait
# v3.2.34: 模块列表 (module.prop 路径列表, awk 用 getline 读)
: > "$TMPD/07_mods" 2>/dev/null
MI=0
for mp in "$MROOT"/*/module.prop; do
  [ -r "$mp" ] || continue
  MI=$((MI + 1))
  printf '%s\n' "$mp" >> "$TMPD/07_mods"
done
# v3.2.34: 无 module.prop 的目录仍展示, 名称回退为目录名 (沿用 v3.1.9 行为)
: > "$TMPD/08_noprop" 2>/dev/null
for d in "$MROOT"/*/; do
  [ -d "$d" ] || continue
  [ -r "${d}module.prop" ] && continue
  m=${d%/}; m=${m##*/}
  [ -n "$m" ] || continue
  if [ -e "${d}disable" ]; then EN=false; else EN=true; fi
  printf '%s %s\n' "$m" "$EN" >> "$TMPD/08_noprop"
done

# v3.2.34: 一次 awk 处理全部数据源
# v3.2.34: 先过滤掉不存在的文件, 避免 awk fatal 导致全部指标丢失
ARGS=""
for tf in "$TMPD/01_thermal" "$TMPD/02_battery" "$TMPD/03_storage" "$TMPD/04_net"           "$TMPD/05_ps" "$TMPD/06_logcat" "$TMPD/07_mods" "$TMPD/08_noprop"; do
  [ -f "$tf" ] && ARGS="$ARGS $tf"
done
SHELLR=$(awk -v phase=all -v mroot="$MROOT" "$AWKPROG" $ARGS 2>/dev/null)
# v3.2.34: 并发保护 - 用 $$ 唯一目录, 结束时清理自己 (原 rm -rf 与下轮采集竞争)
TMPCLEAN="$TMPD"
# 拆分各段输出 (每段以 TAG: 前缀输出一行)
# v3.2.34: 纯 shell 按行读 + case 分发, 0 fork (原 7 次 sed 各 ~25ms)
THERMALS=''; BATT=''; STORAGE=''; NETDEVS=''; PROCS=''; LOGS=''; MODS=''
while IFS= read -r line; do
  tag=${line%%:*}
  body=${line#*:}
  [ -n "$body" ] || continue
  case "$tag" in
    THERMAL) THERMALS="$THERMALS$body" ;;
    BATTERY) BATT="$body" ;;
    STORAGE) STORAGE="$STORAGE$body" ;;
    NET) NETDEVS="$NETDEVS$body" ;;
    PROC) PROCS="$PROCS$body" ;;
    LOG) LOGS="$LOGS$body" ;;
    MOD) MODS="$MODS$body" ;;
  esac
done <<ATRIA_EOF
$SHELLR
ATRIA_EOF
case "$THERMALS" in *,) THERMALS=${THERMALS%,};; esac
case "$STORAGE" in *,) STORAGE=${STORAGE%,};; esac
case "$NETDEVS" in *,) NETDEVS=${NETDEVS%,};; esac
case "$PROCS" in *,) PROCS=${PROCS%,};; esac
case "$LOGS" in *,) LOGS=${LOGS%,};; esac
case "$MODS" in *,) MODS=${MODS%,};; esac
[ -n "$BATT" ] || BATT='{}'

# v3.2.34: 清理本次临时目录
[ -n "$TMPCLEAN" ] && rm -rf "$TMPCLEAN" 2>/dev/null

printf '{"device_id":"%s","timestamp":%s,"mem":{"total_mb":%s,"used_mb":%s,"avail_mb":%s,"percent":%s},"cpu":{"percent":%s},"thermal":[%s],"battery":%s,"storage":[%s],"net":[%s],"processes":[%s],"logcat":[%s],"modules":[%s]}\n' \
  "$(json_esc "$DEV")" "$(date +%s)" "$MEM_TOTAL" "$MEM_USED" "$MEM_AVAIL" "$MEM_PCT" "$CPU_PCT" "$THERMALS" "$BATT" "$STORAGE" "$NETDEVS" "$PROCS" "$LOGS" "$MODS"