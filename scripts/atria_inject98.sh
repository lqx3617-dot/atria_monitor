#!/system/bin/sh
# Atria Monitor v3.4.88 - 数据注入器 (inject_*)
# v3.3.1: du/wakelock 注入点修复 (inject_kernel 追加后插入点错位)
# v3.4.13: 新增 inject_power — 应用耗电排行榜 (dumpsys batterystats --charged 解析)
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
    # v3.4.14: $_WJ 含 | (wakelock 条目分隔) 会击穿 sed 分隔符产生 bad pattern,
    # 坏 JSON 触发主循环括号防护栏丢弃整个采样, power/du 等后续字段全部连带丢失 (面板没数据)。
    # 改纯 shell 拼接 (与 inject_power/inject_kernel 同构): sanitize 后剥尾 } 追加, 零 sed
    _WJ=$(printf '%s' "$_WJ" | tr -cd 'A-Za-z0-9._;,-')
    if [ -n "$_WJ" ]; then
      case "$DATA" in
        '{'*'}') DATA="${DATA%?},\"wakelock\":\"$_WJ\"}" ;;
      esac
    fi
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
      # v3.4.81: du 加 timeout 保护 — 445 个目录展开偶发慢 (实测 1.9s, 闪存慢时 10-30s), 超时跳过该源
      # 注意: timeout 只包 du 本身 (包 sh -c 管道时 toybox timeout 信号传递有 bug, 实测卡满 15s)
      _DIRS=$(timeout 15 du -s "$_SRC"/* 2>/dev/null | sort -rn | head -5)
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
    # v3.4.14: 与 inject_wl 同构改纯 shell 拼接 — sed | 分隔符会被内容里的 | 击穿
    case "$DATA" in
      '{'*'}') DATA="${DATA%?},\"du\":{$DU_CACHE}}" ;;
    esac
  fi
}

PW_CACHE=''
# v3.4.15: 首次立即注入 (初始化为满值), 面板打开约 5 秒就有耗电排行;
# 之后每 25 采样周期 (~100s) 刷新 (mAh 为累计值变化慢, 无需高频)
# v3.4.55 (M3): 注释与实际 tick 同步 — 原注释写 15 周期, 代码已改为 25
PW_TICK=15
BS_TMP='/tmp/.atria_bs.txt'
PW_TMP='/tmp/.atria_pw.txt'
MAP_TMP='/tmp/.atria_uidmap.txt'

inject_power() {
  PW_TICK=$((PW_TICK + 1))
  if [ "$PW_TICK" -ge 25 ]; then
    PW_TICK=0
    PW_CACHE=''
    dumpsys batterystats --charged > "$BS_TMP" 2>/dev/null
    if [ -s "$BS_TMP" ]; then
      # 解析 UID 耗电 top6 (mAh>0.5 过滤噪声; uid 只允许 u+字母数字, 防 JSON 注入)
      # v3.4.17: 阈值 5 → 0.5 — batterystats 重置/插拔后 mAh 从 0 开始累计,
      # 早期值全部 <5 会被整体过滤, PW_CACHE 为空, 面板耗电排行无数据
      grep -E '^ +UID u' "$BS_TMP" 2>/dev/null | awk '{
        uid = $2; sub(/:$/, "", uid)
        if (uid !~ /^u[0-9a-z]+$/) next
        mah = $3 + 0
        if (mah > 0.5) printf "%s %.1f\n", uid, mah
      }' | sort -t' ' -k2 -rn | head -6 > "$PW_TMP" 2>/dev/null
      _SCR=$(grep -oE 'Screen on discharge: [0-9]+' "$BS_TMP" 2>/dev/null | head -1 | grep -oE '[0-9]+')
      _TOT=$(grep -oE 'Computed drain: [0-9]+' "$BS_TMP" 2>/dev/null | head -1 | grep -oE '[0-9]+')
      if [ -s "$PW_TMP" ]; then
        # UID→包名 join: u0a352 → uid:10352 (pm list packages -U)
        # v3.4.62: 加 8s 超时 (裸跑实测可挂起 1800s, 拖垮采集循环)
        timeout 8 pm list packages -U 2>/dev/null | awk -F'[: ]' '{
          gsub(/package:/, "", $2); gsub(/uid:/, "", $NF)
          if ($NF ~ /^[0-9]+$/) print $NF, $2
        }' > "$MAP_TMP" 2>/dev/null
        # 关联数组 join, 包名合法性校验, ? 兜底
        _PWJ=$(awk 'NR==FNR { map[$1] = $2; next }
          { uid = "10" substr($1, 4)
            pkg = map[uid]; if (pkg == "") pkg = "?"
            if (pkg !~ /^[A-Za-z0-9._-]+$/) pkg = "?"
            printf "{\"pkg\":\"%s\",\"mah\":%.1f},", pkg, $2 }' "$MAP_TMP" "$PW_TMP" 2>/dev/null)
        if [ -n "$_PWJ" ]; then
          _PWJ="${_PWJ%,}"
          PW_CACHE="\"top\":[$_PWJ],\"screen_on\":${_SCR:-0},\"total\":${_TOT:-0}"
        fi
      fi
    fi
  fi
  if [ -n "$PW_CACHE" ]; then
    # v3.4.13: 与 inject_kernel 同构 — ${DATA%?} 剥根 }, 追加 ,"power":{...} 末尾两 } 分别闭合 power 对象与根对象
    # 括号不平衡会触发主循环防护栏丢弃整个采样 (面板直接无数据), 必须精确
    case "$DATA" in *'}') DATA="${DATA%?},\"power\":{$PW_CACHE}}" ;; esac
  fi
}

# v3.4.20: 应用名标签注入 — 把 pkg_label.sh 生成的包名->应用名映射注入 status.json
# 前端耗电排行详情直接读 d.labels, 无需额外异步 exec (exec 桥接偶发吞返回)
# v3.4.40: labels 改为写 sidecar — 2393B (18.9%) 的准静态数据不再每周期写进主 JSON
# 前端 poll 时合并: d.labels 为空则读 /data/local/tmp/atria_static_labels.json
# v3.4.53: LB_TICK 改名 LB_CACHE_TICK — 与 collect_loop.sh 的 pkg_label 刷新计数器
# (原同名 LB_TICK, 语义完全不同: 那个是 300 周期刷新, 这个是 10 周期缓存) 分离, 避免互相干扰
LB_CACHE_TICK=0
LB_CACHE=''
_LB_SIDE_LAST=''
inject_labels() {
  LB_CACHE_TICK=$((LB_CACHE_TICK + 1))
  # v3.4.40: tick 缓存 (10 周期 ~40s) — 应用名是静态数据, 每次 awk 是浪费
  if [ "$LB_CACHE_TICK" -lt 10 ] && [ -n "$LB_CACHE" ]; then
    # v3.4.40: 命中缓存不再注入主 JSON (labels 走 sidecar)
    return 0
  fi
  LB_CACHE_TICK=0
  LB_FILE='/data/local/tmp/atria_labels.conf'
  [ -f "$LB_FILE" ] || return
  # v3.4.40: awk 脚本独立成文件 labels.awk (同 logcat.awk 模式), 彻底绕开 shell 转义
  local AWK_F="$DIR/labels.awk"
  [ -f "$AWK_F" ] || AWK_F='/data/adb/modules/atria_monitor/scripts/labels.awk'
  local LB_OUT
  LB_OUT=$(awk -f "$AWK_F" "$LB_FILE" 2>/dev/null)
  LB_CACHE="$LB_OUT"
  # v3.4.40: labels 写 sidecar, 主 JSON 不再含此字段 (省 18.9% 写入量)
  # 内容没变就不写 (应用名极少变化)
  if [ -n "$LB_CACHE" ] && [ "$LB_CACHE" != "$_LB_SIDE_LAST" ]; then
    printf '%s\n' "{\"labels\":{$LB_CACHE}}" > /data/local/tmp/atria_static_labels.json.new 2>/dev/null
    if [ -s /data/local/tmp/atria_static_labels.json.new ]; then
      chmod 644 /data/local/tmp/atria_static_labels.json.new 2>/dev/null
      mv /data/local/tmp/atria_static_labels.json.new /data/local/tmp/atria_static_labels.json 2>/dev/null
    else
      rm -f /data/local/tmp/atria_static_labels.json.new 2>/dev/null
    fi
    _LB_SIDE_LAST="$LB_CACHE"
  fi
}

# v3.4.22: 媒体播放状态注入 — AI payload 和面板需要知道谁在放音乐
# 数据源: dumpsys media_session 的 Audio playback 段 (最近播放列表) + sessions state=3
# 缓存 20 个采样周期 (~100s), 播放状态变化频率低
MP_TICK=0
MP_CACHE=''
detect_mp_pkgs() {
  local MS SEC PKGS
  MS=$(dumpsys media_session 2>/dev/null)
  [ -z "$MS" ] && return
  SEC=$(printf '%s\n' "$MS" | sed -n '/Audio playback/,/^Media session config/p' 2>/dev/null)
  PKGS=$(printf '%s\n' "$SEC" | grep -oE 'packages=[A-Za-z0-9._-]+' 2>/dev/null | sed 's/packages=//' | sort -u)
  [ -z "$PKGS" ] && return
  echo "$PKGS"
}

inject_media() {
  MP_TICK=$((MP_TICK + 1))
  if [ "$MP_TICK" -ge 20 ] || [ -z "$MP_CACHE" ]; then
    MP_TICK=0
    local PKGS OUT P
    PKGS=$(detect_mp_pkgs 2>/dev/null)
    OUT=''
    for P in $PKGS; do
      [ -n "$P" ] || continue
      case "$P" in *[!A-Za-z0-9._-]*) continue ;; esac
      if [ -n "$OUT" ]; then OUT="$OUT,\"$P\""; else OUT="\"$P\""; fi
    done
    [ -n "$OUT" ] && MP_CACHE="$OUT"
  fi
  if [ -n "$MP_CACHE" ] && [ -n "$DATA" ]; then
    case "$DATA" in *'}') DATA="${DATA%?},\"media_playing\":[$MP_CACHE]}" ;; esac
  fi
}

# v3.4.25: 电池增强注入 — 电池健康度/循环次数/充电功率/型号
# 数据源: /sys/class/power_supply/battery/ (oneplus/oppo 高通平台通用节点)
# SoH = charge_full / charge_full_design × 100% (实际满电 vs 设计容量)
# 充电功率 W = current_now(μA) × voltage_now(μV) / 1e12 (放电时为负, 表示放电功率)
# 健康度文字 Good/Fair/Poor 来自 BMS 固件判断, 比算出来的更准
BE_TICK=0
BE_CACHE=''
inject_batt_ext() {
  BE_TICK=$((BE_TICK + 1))
  if [ "$BE_TICK" -ge 30 ] || [ -z "$BE_CACHE" ]; then
    BE_TICK=0
    BE_CACHE=''
    local _B=/sys/class/power_supply/battery
    [ -r "$_B/charge_full" ] || _B=/sys/class/power_supply/bms
    [ -r "$_B/charge_full" ] || return
    local _CF _CD _CYC _HLT _CUR _VOL _MOD _PWR _SOH _J
    _CF=$(cat "$_B/charge_full" 2>/dev/null)
    _CD=$(cat "$_B/charge_full_design" 2>/dev/null)
    _CYC=$(cat "$_B/cycle_count" 2>/dev/null)
    _HLT=$(cat "$_B/health" 2>/dev/null)
    _CUR=$(cat "$_B/current_now" 2>/dev/null)
    _VOL=$(cat "$_B/voltage_now" 2>/dev/null)
    _MOD=$(cat "$_B/model_name" 2>/dev/null)
    # 数值合法性: 只允许整数 (含负数, current_now 放电为负)
    case "$_CF" in *[!0-9]*) _CF=0;; esac
    case "$_CD" in *[!0-9]*) _CD=0;; esac
    case "$_CYC" in *[!0-9]*) _CYC=0;; esac
    case "$_CUR" in *[!0-9-]*) _CUR=0;; esac
    case "$_VOL" in *[!0-9]*) _VOL=0;; esac
    # 文本字段: 只允许字母数字空格下划线连字符 (防 JSON 注入)
    case "$_HLT" in *[!A-Za-z0-9\ _-]*) _HLT='';; esac
    case "$_MOD" in *[!A-Za-z0-9\ _-]*) _MOD='';; esac
    _J=''
    [ "$_CD" -gt 0 ] && [ "$_CF" -gt 0 ] && {
      _SOH=$(( _CF * 100 / _CD ))
      [ "$_SOH" -gt 150 ] && _SOH=0   # 异常值 (设计容量读错), 不报
      [ "$_SOH" -gt 0 ] && _J="\"soh\":$_SOH"
    }
    [ -n "$_CYC" ] && [ "$_CYC" -gt 0 ] && _J="${_J:+$_J,}\"cycle_count\":$_CYC"
    [ -n "$_HLT" ] && _J="${_J:+$_J,}\"health\":\"$_HLT\""
    # 实时功率: μA×μV = pW, /1e12 → W; 放电 current 为负 → 功率为负
    if [ "$_CUR" != "0" ] && [ "$_VOL" -gt 0 ]; then
      _PWR=$(awk -v c="$_CUR" -v v="$_VOL" 'BEGIN { printf "%.2f", c * v / 1000000000000 }')
      _J="${_J:+$_J,}\"power_w\":$_PWR"
    fi
    [ -n "$_MOD" ] && _J="${_J:+$_J,}\"model\":\"$_MOD\""
    [ -n "$_J" ] && BE_CACHE="$_J"
  fi
  if [ -n "$BE_CACHE" ] && [ -n "$DATA" ]; then
    # 剥根 } → 追加 ,"batt_ext":{...} → 补回根 }
    case "$DATA" in *'}') DATA="${DATA%?},\"batt_ext\":{$BE_CACHE}}" ;; esac
  fi
}
# v3.4.25: 每应用流量排行注入 — dumpsys netstats 的 per-uid 累计流量
# 输出示例: {uid=10349,package=com.tencent.mm}=2080 (2080KB)
# 前端网速详情弹窗 + AI payload 用, 回答"谁在偷流量"
NS_TICK=0
NS_CACHE=''
inject_net_stats() {
  NS_TICK=$((NS_TICK + 1))
  if [ "$NS_TICK" -ge 60 ] || [ -z "$NS_CACHE" ]; then
    NS_TICK=0
    NS_CACHE=''
    # 只取 per-uid 汇总行 ({uid=X,package=Y}=KB), 排除 ident/cookie 行
    _NSJ=$(dumpsys netstats 2>/dev/null | grep -oE '\{uid=[0-9]+,package=[A-Za-z0-9._-]+\}=[0-9]+' 2>/dev/null | head -8 | awk -F'[=,}]' '{
      uid = $2; pkg = $4; kb = $NF + 0
      if (kb < 512) next            # <0.5MB 的应用不报, 减少噪声
      if (pkg !~ /^[A-Za-z0-9._-]+$/) next   # 防 JSON 注入
      printf "\"%s\":%.1f,", pkg, kb / 1024   # KB → MB
    }')
    if [ -n "$_NSJ" ]; then
      NS_CACHE="${_NSJ%,}"
    fi
  fi
  if [ -n "$NS_CACHE" ] && [ -n "$DATA" ]; then
    # 剥根 } → 追加 ,"net_stats":{...} → 补回根 }
    case "$DATA" in *'}') DATA="${DATA%?},\"net_stats\":{$NS_CACHE}}" ;; esac
  fi
}
# v3.4.32: 屏幕状态注入 — mWakefulness=Awake(亮屏) / Asleep(息屏)
# 数据源: dumpsys power 的 mWakefulness 字段 (息屏时 wakelock 排行才有意义)
# screen.off_secs 为本次息屏持续秒数 (内存累计, 进程重启清零)
SCREEN_OFF_SINCE=''
SC_TICK=0
SC_CACHE=''
inject_screen() {
  SC_TICK=$((SC_TICK + 1))
  if [ "$SC_TICK" -ge 5 ] || [ -z "$SC_CACHE" ]; then
    SC_TICK=0
    SC_CACHE=''
    _AW=$(dumpsys power 2>/dev/null | grep -m1 'mWakefulness=' | grep -oE 'Awake|Asleep')
    case "$_AW" in
      Awake) _S='on' ;;
      Asleep) _S='off' ;;
      *) _S='' ;;
    esac
    if [ -n "$_S" ]; then
      if [ "$_S" = "off" ]; then
        [ -z "$SCREEN_OFF_SINCE" ] && SCREEN_OFF_SINCE=$(date +%s)
      else
        SCREEN_OFF_SINCE=''
      fi
      _DUR=''
      if [ "$_S" = "off" ] && [ -n "$SCREEN_OFF_SINCE" ]; then
        _DUR=$(( $(date +%s) - SCREEN_OFF_SINCE ))
      fi
      SC_CACHE="\"state\":\"$_S\"${_DUR:+,\"off_secs\":$_DUR}"
    fi
  fi
  if [ -n "$SC_CACHE" ] && [ -n "$DATA" ]; then
    case "$DATA" in *'}') DATA="${DATA%?},\"screen\":{$SC_CACHE}}" ;; esac
  fi
}

# v3.4.32: 活动通知注入 — cmd notification list 的 pkg 计数
# 数据源: cmd notification list (每行一条: 0|pkg|id|tag|userId)
# 按应用聚合 top8 + 总数, 前台服务常驻通知也在内 (AI 可结合 media_playing 判断是否在播放)
NT_TICK=0
NT_CACHE=''
inject_notif() {
  NT_TICK=$((NT_TICK + 1))
  if [ "$NT_TICK" -ge 30 ] || [ -z "$NT_CACHE" ]; then
    NT_TICK=0
    NT_CACHE=''
    _NL=$(cmd notification list 2>/dev/null)
    [ -z "$_NL" ] && return
    # 每行第 2 字段为包名, 只留合法包名, 计数后排序取 top8
    _NTJ=$(printf '%s\n' "$_NL" | awk -F'|' '{pkg=$2; if (pkg ~ /^[A-Za-z0-9._-]+$/) print pkg}' \
      | sort | uniq -c | sort -rn | head -8 \
      | awk '{printf "\"%s\":%d,", $2, $1}')
    _TOT=$(printf '%s' "$_NL" | grep -c '|' 2>/dev/null)
    case "$_TOT" in *[!0-9]*) _TOT=0;; esac
    if [ -n "$_NTJ" ]; then
      NT_CACHE="\"total\":$_TOT,\"apps\":{${_NTJ%,}}"
    fi
  fi
  if [ -n "$NT_CACHE" ] && [ -n "$DATA" ]; then
    case "$DATA" in *'}') DATA="${DATA%?},\"notifications\":{$NT_CACHE}}" ;; esac
  fi
}

# v3.4.32: 应用崩溃记录注入 — /data/system/dropbox 的 TOMBSTONE/ANR/crash
# 数据源: SYSTEM_TOMBSTONE@*.txt.gz (zcat 首行 'Process name is X'), data_app_anr, data_app_native_crash
# 采近 24h 计数 + 崩溃进程名 (logcat 抓不住的持久存证, 进程名可能含中文)
# v3.4.32: 分类计数 (app/system/tool) + 爆发检测 (1 小时窗内同进程 >=3 条)
# - app:    应用自身进程 (含 root 级第三方二进制, 如 ./光头强vip)
# - system: 系统编译/守护进程 (dex2oat 等), 跟安装更新有关, 不属于应用故障
# - tool:   UI 自动化工具 (uiautomator dump), 抓窗口层级时自身崩溃, 与被测应用无关
# burst: 爆发进程的 {process, count, window_mins}, 无爆发时为 null
DB_TICK=0
DB_CACHE=''
inject_crashes() {
  DB_TICK=$((DB_TICK + 1))
  if [ "$DB_TICK" -ge 120 ] || [ -z "$DB_CACHE" ]; then
    DB_TICK=0
    DB_CACHE=''
    _CNT=$(find /data/system/dropbox -type f -mmin -1440 2>/dev/null | grep -cE 'TOMBSTONE|anr|crash')
    case "$_CNT" in *[!0-9]*) _CNT=0;; esac
    if [ "$_CNT" -gt 0 ]; then
      # 输出行: mtime|类|进程名  (进程名内的 | 替换为 ; 防破坏 JSON 与 awk 分割)
      _CLS=$(find /data/system/dropbox -type f -mmin -1440 2>/dev/null | grep -E 'TOMBSTONE|anr|crash' \
        | while read -r _F; do
            _T=$(stat -c %Y "$_F" 2>/dev/null)
            _P=$(zcat "$_F" 2>/dev/null | grep -m1 'Process name is' \
              | sed 's/.*Process name is //; s/, uid.*//; s/^\.\///; s/|/;/g' | cut -c1-40)
            [ -z "$_P" ] && continue
            case "$_P" in
              *uiautomator*|*app_process*|*com.android.commands*) _C='tool' ;;
              *dex2oat*|*installd*|*system_server*) _C='system' ;;
              # v3.4.78: vendor HAL 进程独立归类 (硬件抽象层崩溃≠用户应用故障, AI 诊断需区分)
              */vendor/*|*android.hardware.*|*hal_*|*vendor.*) _C='vendor' ;;
              *) _C='app' ;;
            esac
            printf '%s|%s|%s\n' "${_T:-0}" "$_C" "$_P"
          done | sort -rn | head -40)
      # recent: 崩溃进程名列表 (| 分隔)
      _LAST=$(printf '%s\n' "$_CLS" | awk -F'|' '{print $3}' | head -12 | tr '\n' '|' | sed 's/|$//')
      # JSON 注入防护: 只拒绝双引号/反斜杠/控制字符, 允许中文进程名 (光头强vip 等)
      case "$_LAST" in
        *'"'*|*'\\'*|*$'\n'*|*$'\t'*) _LAST='' ;;
      esac
      # 分类计数 (精确匹配行首或 | 后接类名, 防止进程名里的 app/tool 片段误匹配)
      _A=$(printf '%s\n' "$_CLS" | grep -cE '^[0-9]+\|app\|')
      _S=$(printf '%s\n' "$_CLS" | grep -cE '^[0-9]+\|system\|')
      _T2=$(printf '%s\n' "$_CLS" | grep -cE '^[0-9]+\|tool\|')
      _V=$(printf '%s\n' "$_CLS" | grep -cE '^[0-9]+\|vendor\|')
      # 爆发检测: 同类同进程 1 小时窗内 >=3 条 (多个爆发取 count 最大者)
      _BURST=$(printf '%s\n' "$_CLS" | awk -F'|' '
        { key = $2 "|" $3; cnt[key]++;
          if (last[key] == "" || $1 > last[key]) last[key] = $1;
          if (first[key] == "" || $1 < first[key]) first[key] = $1; }
        END { for (k in cnt) if (cnt[k] >= 3) {
          split(k, p, "|");
          printf "%d|%s|%d\n", cnt[k], p[2], int((last[k] - first[k]) / 60);
        } }' | sort -rn | head -1)
      _BURST_J='null'
      if [ -n "$_BURST" ]; then
        _BC=$(printf '%s' "$_BURST" | cut -d'|' -f1)
        _BP=$(printf '%s' "$_BURST" | cut -d'|' -f2)
        _BW=$(printf '%s' "$_BURST" | cut -d'|' -f3)
        case "$_BW" in *[!0-9]*) _BW=0;; esac
        # JSON 注入防护: 进程名拒绝双引号/反斜杠/控制字符 (允许中文)
        case "$_BP" in
          *'"'*|*'\\'*|*$'\n'*|*$'\t'*) _BP='' ;;
        esac
        if [ -n "$_BP" ]; then
          _BURST_J="{\"process\":\"$_BP\",\"count\":$_BC,\"window_mins\":$_BW}"
        fi
      fi
      DB_CACHE="\"count_24h\":$_CNT,\"app\":$_A,\"system\":$_S,\"tool\":$_T2,\"vendor\":$_V,\"recent\":\"$_LAST\",\"burst\":$_BURST_J,\"updated_ts\":$(date +%s)"
    else
      DB_CACHE="\"count_24h\":0,\"app\":0,\"system\":0,\"tool\":0,\"vendor\":0,\"recent\":\"\",\"burst\":null,\"updated_ts\":$(date +%s)"
    fi
  fi
  if [ -n "$DB_CACHE" ] && [ -n "$DATA" ]; then
    case "$DATA" in *'}') DATA="${DATA%?},\"crashes\":{$DB_CACHE}}" ;; esac
  fi
}

# v3.4.32: 系统安全防护注入 — 锁机/木马三项威胁面 + 新增包检测
# 威胁模型 (锁机类 ransomware/locker 必经之路):
#   1. 设备管理器 (Device Admin): 拿到后可 lockNow() 改锁屏密码 -> 锁机
#   2. 辅助服务 (AccessibilityService): 模拟点击绕验证、读屏 -> 中危
#   3. 通知监听 (NotificationListenerService): 读验证码 -> 中危
#   4. 锁屏凭据突然出现: lockscreen.password_type 由 null 变非 null
#   5. 新增未知包: 与基线快照 diff (侧载安装痕迹)
# 白名单: 系统包 (com.android.*) 与已知合法服务放行, 其余一律报告
# 注意: 各检测块的输出必须 $() 捕获进 _THR, 不能直 printf 到 stdout (会污染 status.json)
SEC_TICK=0
SEC_CACHE=''
SEC_BASELINE=/data/local/tmp/atria_sec_baseline.txt
# v3.4.80: 格机检测(被动) — /data/data 目录数基线 (首次采样记入, 降幅>=10% 报警)
# 注意: 这是检测层只告警不拦截; 主动拦截层 guard_watch.sh (v3.4.79+设备管理器拦截, v3.4.81+进程命令行扫描) 已恢复部署
SEC_DATA_BASE=''
inject_security() {
  SEC_TICK=$((SEC_TICK + 1))
  # v3.4.62: 周期 45 -> 90 (~较慢周期下约 20 分钟一次), 减少 pm list/dumpsys 阻塞机会
  if [ "$SEC_TICK" -ge 90 ] || [ -z "$SEC_CACHE" ]; then
    SEC_TICK=0
    SEC_CACHE=''
    _THR=''
    # v3.4.62: dumpsys device_policy 实测 160ms, 加 5s 超时保护 (卡死时整个采集循环停摆)
    _DA=$(timeout 5 dumpsys device_policy 2>/dev/null | grep -oE 'Admin: ComponentInfo\{[^}]+\}' | sed 's/Admin: ComponentInfo{//; s/}$//')
    if [ -n "$_DA" ]; then
      _THR="${_THR}$(printf '%s\n' "$_DA" | while read -r _C; do
        _PKG=$(printf '%s' "$_C" | cut -d/ -f1)
        case "$_PKG" in
          com.android.*) ;;
          *) printf '\nhigh|device_admin: %s' "$_C" ;;
        esac
      done)"
    fi
    # ---- 2. 辅助服务 ----
    _ACC=$(settings get secure enabled_accessibility_services 2>/dev/null)
    if [ -n "$_ACC" ] && [ "$_ACC" != "null" ]; then
      _THR="${_THR}$(printf '%s' "$_ACC" | tr ':' '\n' | while read -r _C; do
        [ -z "$_C" ] && continue
        _PKG=$(printf '%s' "$_C" | cut -d/ -f1)
        case "$_PKG" in
          com.android.*|com.google.*) ;;
          *) printf '\nhigh|accessibility: %s' "$_C" ;;
        esac
      done)"
    fi
    # ---- 3. 通知监听 ----
    _NL2=$(settings get secure enabled_notification_listeners 2>/dev/null)
    if [ -n "$_NL2" ] && [ "$_NL2" != "null" ]; then
      _THR="${_THR}$(printf '%s' "$_NL2" | tr ':' '\n' | while read -r _C; do
        [ -z "$_C" ] && continue
        _PKG=$(printf '%s' "$_C" | cut -d/ -f1)
        case "$_PKG" in
          com.android.*|com.google.*) ;;
          *) printf '\nmed|notif_listener: %s' "$_C" ;;
        esac
      done)"
    fi
    # ---- 4. 悬浮窗权限 (v3.4.78: SYSTEM_ALERT_WINDOW 非系统包 = 中危, 锁机木马盖屏途径) ----
    # dumpsys appops 一次性导出, awk 提取 Package 段内 SYSTEM_ALERT_WINDOW (allow) 的包名
    # 允许列表: 系统包 + 宿主助手 + 已知合法悬浮窗应用 (输入法/launcher/系统 UI)
    _OV=$(timeout 8 dumpsys appops 2>/dev/null | grep -B1 'SYSTEM_ALERT_WINDOW (allow)' | grep 'Package' \
      | sed 's/.*Package //; s/:.*//' | sort -u)
    if [ -n "$_OV" ]; then
      _THR="${_THR}$(printf '%s\n' "$_OV" | while read -r _P; do
        [ -z "$_P" ] && continue
        case "$_P" in
          # 系统包与厂商包放行
          com.android.*|com.google.*|com.oplus.*|com.heytap.*|com.coloros.*|com.oppo.*) ;;
          # v3.4.78: 宿主助手与已知合法应用放行 (面板/AI 助手/输入法/launcher 本身就需要悬浮窗)
          com.ai.assistance.operit|com.niki914.zafiro|com.iflytek.inputmethod|com.gtq.launcher.*|com.microsoftsdk.crossdeviceservicebroker) ;;
          *) printf '\nmed|overlay: %s' "$_P" ;;
        esac
      done)"
    fi
    # ---- 5. 锁屏凭据 ----
    _LP=$(settings get secure lockscreen.password_type 2>/dev/null)
    if [ -n "$_LP" ] && [ "$_LP" != "null" ]; then
      _THR="${_THR}
med|lockscreen_credential: password_type=$_LP"
    fi
    # ---- 6. 格机/数据破坏意图 (v3.4.78: recovery wipe 意图 + 应用数据批量消失) ----
    # 6a. recovery 格机命令文件: 正常不存在, 出现且含 --wipe_data = 高危 (格机意图已提交)
    if [ -f /cache/recovery/command ]; then
      _WCmd=$(cat /cache/recovery/command 2>/dev/null | tr '\n' ' ' | cut -c1-60)
      case "$_WCmd" in
        *'"'*|*'\\'*) _WCmd='' ;;
      esac
      if [ -n "$_WCmd" ]; then
        _THR="${_THR}
high|wipe_intent: ${_WCmd}"
      fi
    fi
    # 6b. shutdown-checkpoints 里出现 recovery/wipe 参数 = 中危 (重启进 recovery 的请求)
    _SCP=$(grep -h 'Shutdown request' /data/system/shutdown-checkpoints/* 2>/dev/null \
      | grep -icE 'recovery|wipe' || true)
    case "$_SCP" in *[!0-9]*) _SCP=0;; esac
    if [ "$_SCP" -gt 0 ]; then
      _THR="${_THR}
med|recovery_request: 近期关机请求含 recovery/wipe 参数"
    fi
    # 6c. 应用数据批量消失: /data/data 目录数与包缓存比对, 短时间锐减 = 数据破坏进行中
    # (基线包数记 SEC_DATA_BASE, 降幅 >30% 触发高危; 首次运行只记基线)
    _DN=$(ls /data/data 2>/dev/null | wc -l)
    case "$_DN" in *[!0-9]*) _DN=0;; esac
    if [ "$_DN" -gt 0 ]; then
      if [ -z "$SEC_DATA_BASE" ]; then
        SEC_DATA_BASE=$_DN
      else
        _Drop=$(( (SEC_DATA_BASE - _DN) * 100 / SEC_DATA_BASE ))
        if [ "$_Drop" -ge 30 ]; then
          _THR="${_THR}
high|data_wipe: /data/data 目录数 $SEC_DATA_BASE -> $_DN (降幅 ${_Drop}%)"
        elif [ "$_Drop" -ge 10 ]; then
          _THR="${_THR}
med|data_loss: /data/data 目录数 $SEC_DATA_BASE -> $_DN (降幅 ${_Drop}%)"
        fi
      fi
    fi
    # v3.4.62: pm list packages 实测可卡死采集循环 (通道挂起 1800s 实测), 改用 8s 超时 +
    # 缓存优先: SEC_PKG_CACHE 有效期内直接复用, 不再每周期都跑
    if [ -z "$SEC_PKG_CACHE" ]; then
      _CUR=$(timeout 8 pm list packages 2>/dev/null | sed 's/^package://; s/\r$//' | sort)
      if [ -n "$_CUR" ]; then
        SEC_PKG_CACHE="$_CUR"
      else
        # v3.4.62: pm list 失败/超时 — 跳过本轮新增包检测, 保住采集周期不崩
        _CUR=''
      fi
    else
      _CUR="$SEC_PKG_CACHE"
    fi
    if [ -n "$_CUR" ]; then
      printf '%s\n' "$_CUR" > /tmp/_sec_cur.txt
      if [ ! -s "$SEC_BASELINE" ]; then
        # 首次运行: 生成基线, 不报告
        cp /tmp/_sec_cur.txt "$SEC_BASELINE" 2>/dev/null
      else
        _NEW=$(comm -13 "$SEC_BASELINE" /tmp/_sec_cur.txt 2>/dev/null | head -5)
        if [ -n "$_NEW" ]; then
          _THR="${_THR}$(printf '%s\n' "$_NEW" | while read -r _P; do
            [ -n "$_P" ] && printf '\ninfo|new_package: %s' "$_P"
          done)"
        fi
      fi
      rm -f /tmp/_sec_cur.txt
    fi
    # ---- 汇总 ----
    _H=$(printf '%s\n' "$_THR" | grep -c '^high|')
    _M=$(printf '%s\n' "$_THR" | grep -c '^med|')
    _I=$(printf '%s\n' "$_THR" | grep -c '^info|')
    _TL=$(printf '%s\n' "$_THR" | grep -v '^$' | head -6 | tr '\n' '@' | sed 's/^@//; s/@$//; s/|/;/g')
    case "$_TL" in *'"'*|*'\\'*) _TL='' ;; esac
    if [ "$_H" -gt 0 ]; then _LVL='high'; elif [ "$_M" -gt 0 ]; then _LVL='med'; else _LVL='ok'; fi
    SEC_CACHE="\"level\":\"$_LVL\",\"high\":$_H,\"med\":$_M,\"info\":$_I,\"threats\":\"$_TL\""
  fi
  if [ -n "$SEC_CACHE" ] && [ -n "$DATA" ]; then
    # 剥尾 } 追加 ,"security":{...}, 末尾两个 } 分别闭合 security 对象与根对象 (与 inject_crashes 同构)
    case "$DATA" in *'}') DATA="${DATA%?},\"security\":{$SEC_CACHE}}" ;; esac
  fi
}
# v3.4.40: 安装拦截兜底通道 — install_watch 被杀或 logcat 丢事件时补位
# 每 60 采样周期 (~4 分钟) 做一次 pm list packages 与缓存 diff, 新增包调用 install_scan.sh
IW_TICK=0
IW_CACHE=''
IW_SEEN=/data/local/tmp/atria_install_seen.txt
# v3.4.62: 安全扫描的包名缓存 (pm list packages 耗时且偶发卡死, 缓存复用)
SEC_PKG_CACHE=''
inject_install_fallback() {
  IW_TICK=$((IW_TICK + 1))
  # v3.4.40: 每 60 周期 (~4 分钟) 扫一次, 与 inject_security 的 30 周期错开避免峰值
  if [ "$IW_TICK" -lt 60 ]; then return 0; fi
  IW_TICK=0
  # v3.4.62: pm list packages 加 8s 超时 (裸跑实测可挂起 1800s, 拖垮整个采集循环)
  # 首次运行: 建立_seen缓存, 不告警 (与 SEC_BASELINE 同逻辑, 避免把已装应用全扫一遍)
  if [ ! -s "$IW_SEEN" ]; then
    timeout 8 pm list packages 2>/dev/null | sed 's/^package://; s/\r$//' | sort > "$IW_SEEN"
    return 0
  fi
  # v3.4.62: pm list packages 加 8s 超时 (裸跑实测可挂起 1800s, 拖垮整个采集循环)
  timeout 8 pm list packages 2>/dev/null | sed 's/^package://; s/\r$//' | sort > /tmp/.iw_cur.txt
  # 新增包 = 当前列表 - 已见列表
  _NEWP=$(comm -13 "$IW_SEEN" /tmp/.iw_cur.txt 2>/dev/null | head -5)
  if [ -n "$_NEWP" ]; then
    echo "$_NEWP" | while IFS= read -r _P; do
      [ -n "$_P" ] && sh "$DIR/install_scan.sh" scan "$_P" >> /data/local/tmp/atria_install_log.jsonl 2>/dev/null
    done
    # 更新已见列表
    mv /tmp/.iw_cur.txt "$IW_SEEN" 2>/dev/null
  else
    rm -f /tmp/.iw_cur.txt
  fi
}
# v3.4.40: CPU 大小核实时频率与负载注入
# 数据源: /proc/stat 8 核原始计数器 + /sys/devices/system/cpu/cpu$N/cpufreq/cpuinfo_cur_freq
# 现有 kernel.cpu_clusters 只有频率, 本函数补充各核利用率 (差分算法)
# CPU_TICK=15 (~60s): 采样并计算上一分钟以来的差分利用率
CPU_TICK=0
# 上次采样的原始计数器 (空分隔)
_CPU_PREV=''
CC_CACHE=''
inject_cpu_cores() {
  # v3.4.76: 缓存注入每次都执行 (在 tick 检查之前), 差分计算才受 tick 控制
  # 原实现整个函数体都在 CPU_TICK<15 的 return 之后, 导致缓存只在 1/15 周期注入
  if [ -n "$CC_CACHE" ] && [ -n "$DATA" ]; then
    case "$DATA" in *'}') DATA="${DATA%?},\"cpu_cores\":[$CC_CACHE]}" ;; esac
  fi
  CPU_TICK=$((CPU_TICK + 1))
  if [ "$CPU_TICK" -lt 15 ]; then return 0; fi
  CPU_TICK=0
  # 读出 8 核原始计数: core|busy|total
  local LINE BUSY TOTAL CUR
  CUR=''
  for N in 0 1 2 3 4 5 6 7; do
    LINE=$(awk -v n="cpu$N" '$1==n' /proc/stat 2>/dev/null)
    [ -n "$LINE" ] || continue
    # busy = user+nice+system+irq+softirq+steal ($2+$3+$4+$7+$8)
    # total = busy + idle + iowait ($5+$6)
    SET=$(printf '%s' "$LINE" | awk '{b=$2+$3+$4+$7+$8; t=b+$5+$6; printf "%d %d", b, t}')
    BUSY=$(printf '%s' "$SET" | cut -d' ' -f1)
    TOTAL=$(printf '%s' "$SET" | cut -d' ' -f2)
    # 转十进制去前导零 (shell 算术不认 007)
    BUSY=$((BUSY + 0))
    TOTAL=$((TOTAL + 0))
    if [ -n "$CUR" ]; then CUR="$CUR;"; fi
    CUR="$CUR$N|$BUSY|$TOTAL"
  done
  [ -n "$CUR" ] || return 0
  # 差分: 与上次采样比较
  local N PB PT DB DT PCT FREQ F OUT
  OUT=''
  if [ -n "$_CPU_PREV" ]; then
    IFS=';' read -r c0 c1 c2 c3 c4 c5 c6 c7 <<EOF
$_CPU_PREV
EOF
    PREV_LIST="$c0;$c1;$c2;$c3;$c4;$c5;$c6;$c7"
    for N in 0 1 2 3 4 5 6 7; do
      # 当前行
      CC=$(printf '%s' "$CUR" | cut -d';' -f$((N + 1)))
      # 上次行
      PP=$(printf '%s' "$PREV_LIST" | cut -d';' -f$((N + 1)))
      [ -n "$CC" ] && [ -n "$PP" ] || continue
      CB=$(printf '%s' "$CC" | cut -d'|' -f2)
      CT=$(printf '%s' "$CC" | cut -d'|' -f3)
      PB=$(printf '%s' "$PP" | cut -d'|' -f2)
      PT=$(printf '%s' "$PP" | cut -d'|' -f3)
      DB=$((CB - PB))
      DT=$((CT - PT))
      if [ "$DT" -gt 0 ]; then
        PCT=$(( DB * 100 / DT ))
        [ "$PCT" -gt 100 ] && PCT=100
        [ "$PCT" -lt 0 ] && PCT=0
      else
        PCT=0
      fi
      FREQ=$(cat "/sys/devices/system/cpu/cpu$N/cpufreq/cpuinfo_cur_freq" 2>/dev/null)
      [ -n "$FREQ" ] || FREQ=0
      if [ -n "$OUT" ]; then OUT="$OUT,"; fi
      OUT="$OUT{\"core\":$N,\"freq_khz\":$FREQ,\"util_pct\":$PCT}"
    done
  fi
  _CPU_PREV="$CUR"
  # v3.4.76: 差分结果存缓存, 下次调用由函数头部注入
  if [ -n "$OUT" ]; then
    CC_CACHE="$OUT"
  fi
}

# v3.4.40: 网络质量监测注入
# 数据源: ping 延迟 + wlan0 收发字节/包 + socket 计数
# NETQ_TICK=30 (~2 分钟), ping 3 包约 1.5s
# v3.4.76: 改缓存模式 — 原即时注入下一周期就丢 (同 cpu_cores 的 bug)
NETQ_TICK=0
NQ_CACHE=''
inject_netq() {
  # v3.4.76: 缓存注入每次都执行 (在 tick 检查之前), 差分计算才受 tick 控制
  if [ -n "$NQ_CACHE" ] && [ -n "$DATA" ]; then
    case "$DATA" in *'}') DATA="${DATA%?},\"netq\":$NQ_CACHE}" ;; esac
  fi
  NETQ_TICK=$((NETQ_TICK + 1))
  if [ "$NETQ_TICK" -lt 30 ]; then return 0; fi
  NETQ_TICK=0
  # 1. ping 延迟 (3 包取平均, 超时 2s/包; 失败=0 表示不可达)
  local PSTAT RTT
  PSTAT=$(ping -c 3 -W 2 223.5.5.5 2>/dev/null | tail -1)
  RTT=0
  case "$PSTAT" in
    *rtt*) RTT=$(printf '%s' "$PSTAT" | sed 's/.*= //; s/ ms//' | cut -d'/' -f2) ;;
  esac
  # 2. wlan0 收发字节累计
  local WL RX_B TX_B
  WL=$(grep 'wlan0:' /proc/net/dev 2>/dev/null)
  RX_B=$(printf '%s' "$WL" | awk '{print $2}')
  TX_B=$(printf '%s' "$WL" | awk '{print $10}')
  # 3. socket 总数
  local SOCK
  SOCK=$(grep 'sockets:' /proc/net/sockstat 2>/dev/null | awk '{print $3}')
  local OUT
  OUT="{\"rtt_ms\":${RTT:-0},\"rx_bytes\":${RX_B:-0},\"tx_bytes\":${TX_B:-0},\"sockets\":${SOCK:-0}}"
  # v3.4.76: 结果存缓存, 下次调用由函数头部注入
  NQ_CACHE="$OUT"
}