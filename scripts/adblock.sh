#!/system/bin/sh
# Atria Monitor v3.4.60 - 广告屏蔽引擎 (systemless hosts)
# 借鉴: bindhosts (mount --bind systemless) + AdAway (多源订阅) + anti-AD (规则源)
# 原理: 把广告域名解析到 0.0.0.0, 在 DNS 解析层拦截, 系统级生效, 零常驻进程
#
# 用法:
#   adblock.sh update          下载全部启用源 → 去重 → 剔白白名单 → 生成 hosts
#   adblock.sh apply           挂载 hosts (bind mount, 秒级生效)
#   adblock.sh unapply         解除挂载
#   adblock.sh status          状态 JSON
#   adblock.sh toggle [on|off] 开关
#   adblock.sh benchmark       v3.4.53: 规则源质量评估 — 下载耗时/条数/独有增量/误伤/评分, 自动选最优
#   adblock.sh hit             统计当前被屏蔽连接数
#
# 数据路径 (模块外持久化):
#   /data/adb/atria_ad_sources.conf     规则源 (每行: 启用|名称|URL)
#   /data/adb/atria_ad_whitelist.conf   白名单域名
#   /data/adb/atria_ad_bench.json       规则源评估结果
#   /data/local/tmp/atria_ad_hosts.txt  生成的 hosts 文件
#   /data/adb/atria_ad_state.json       状态文件

VERSION="v3.4.78"
ADB_DIR="/data/adb"
SRC_FILE="$ADB_DIR/atria_ad_sources.conf"
WL_FILE="$ADB_DIR/atria_ad_whitelist.conf"
BENCH_FILE="$ADB_DIR/atria_ad_bench.json"
HOSTS_FILE="/data/local/tmp/atria_ad_hosts.txt"
STATE_FILE="$ADB_DIR/atria_ad_state.json"
SYS_HOSTS="/system/etc/hosts"
TMP_DIR="/data/local/tmp/atria_ad_tmp_$$"
# v3.4.54: 更新进度日志 — 前端边更新边看进度 (后台运行时写, 完成后写 DONE)
PROGRESS_FILE="/data/local/tmp/atria_ad_progress.log"

# v3.4.54: 写进度 (带时间戳, 前端轮询读这个文件显示进度)
log_progress() {
  local msg="$1"
  local ts
  ts=$(date +%s)
  printf '[%s] %s\n' "$ts" "$msg" >> "$PROGRESS_FILE" 2>/dev/null
}

# v3.4.53: 规则源 — 全部默认启用, 覆盖中文区 + 国际
# 1=启用 0=禁用; benchmark 会评估各源质量并推荐最优
DEFAULT_SOURCES='1|anti-AD(中文区首选)|https://raw.githubusercontent.com/NotNoneX/anti-AD/master/anti-ad-domains.txt
1|AdAway官方|https://raw.githubusercontent.com/AdAway/adaway.github.io/master/hosts.txt
1|rentianyu合并源|https://raw.githubusercontent.com/rentianyu/Ad-set-hosts/master/hosts
1|StevenBlack(国际综合)|https://raw.githubusercontent.com/StevenBlack/hosts/master/hosts
1|hblock(国际综合)|https://hblock.molinero.dev/hosts
1|E7KMbb(中文Magisk)|https://raw.githubusercontent.com/E7KMbb/AD-hosts/master/system/etc/hosts'

# v3.4.60: 广告域名例外表 — 优先级高于 PROTECT_DOMAINS。
# 背景: qq.com / kuaishou.com 整域保护时, 广告联盟子域名被连带放行 (filter_protect 的
# 后缀匹配会把 *.qq.com 全部放行), 酷安开屏广告 (GDT 优量汇) / 快手磁力引擎漏拦截。
# 修复: 广告域名在保护过滤里先命中此表 → 不放行, 恢复屏蔽 (filter_protect 第一段校验)。
# 只放确认是广告/埋点业务的子域名, 不影响 qq.com 主站与消息业务。
AD_DOMAINS="gdt.qq.com t.gdt.qq.com otosdk.qq.com adnet.qq.com e.qq.com
mi.gdt.qq.com pgdt.ugdtimg.com
ksad.kuaishou.com open.e.kuaishou.com
pglstatp-toutiao.com
ad.toutiao.com log.snssdk.com pangolin.snssdk.com
adsame.cn
# v3.4.64: 百度联盟/阿里妈妈/京东/拼多多 — 同 v3.4.60 酷安开屏同类问题
# baidu.com/taobao.com/jd.com/pinduoduo.com 整域保护时, 广告/营销子域名被连带放行
# (filter_protect 后缀匹配把 *.baidu.com 全部放行), 百度联盟开屏/信息流漏拦截
# 实测漏拦截: pos.baidu.com -> 14.215.183.31 (真实 IP, 未拦截)
pos.baidu.com cpro.baidu.com mobads.baidu.com mobads-logs.baidu.com
mads.baidu.com e.baidu.com itsdata.baidu.com
clkservice.baidu.com
pcm.channel.baidu.com
dsp.simba.taobao.com simba.taobao.com
amdc.m.taobao.com s_amdc.m.taobao.com
x.jd.com c.jd.com click.shop.jd.com
ads.pinduoduo.com ju.pinduoduo.com
"

# v3.4.53: 核心域名保护问题：**961 条核心域名被屏蔽**——这就是"误伤"真实发生了。微信/QQ/淘宝的域名被 hosts 屏蔽会导致 App 异常。必须加默认保护：表 — 默认放行清单, 防止规则源误伤常用 App
# benchmark 的 CORE_DOMAINS 用来"评分"; 这个表用于实际"剔除"
# (取交集: 误伤过的都保护, 外加国内常用生态)
PROTECT_DOMAINS="google.com android.com googleapis.com gstatic.com github.com githubusercontent.com raw.githubusercontent.com
qq.com weixin.qq.com tencent.com wx.qq.com alibaba.com taobao.com tmall.com bilibili.com douyin.com bytedance.com
jd.com 163.com baidu.com weibo.com xiaomi.com huawei.com apple.com icloud.com microsoft.com opera-mini.net
vip.com pinduoduo.com suning.com meituan.com didiglobal.com cainiao.com
alipay.com antgroup.com mybank.cn cmbchina.com icbc.com.cn
b站.cn zhihu.com douyu.com huya.com kuaishou.com ximalaya.com
mi.com oppo.com vivo.com.cn meizu.com coloros.com
edu.cn gov.cn 12306.cn"

# v3.4.53: 关键段表 — 出现在域名任意位置即保护的标识 (中段匹配)
# 用于: 宿主/io.github.a13e300.ksuwebui 这类 a13e300 在域名中段的保护
# 注意: 只放足够唯一的标识, 避免误伤 (mi/qq/com 这类短词绝不能放)
PROTECT_SEGS="a13e300"

# v3.4.55 (M1 修复): 误伤评分表 — 原代码 do_benchmark 引用 $CORE_DOMAINS 但从未定义,
# core_hit 恒为 0, benchmark 的误伤检测 (30 分项) 完全失效。
# 现在显式定义; 与 PROTECT_DOMAINS 保持同步原则: 评分用子集, 剔除用全集
CORE_DOMAINS="google.com qq.com weixin.qq.com tencent.com wx.qq.com alibaba.com taobao.com
baidu.com bilibili.com douyin.com bytedance.com jd.com 163.com weibo.com xiaomi.com
huawei.com apple.com icloud.com microsoft.com zhihu.com douyu.com huya.com kuaishou.com
alipay.com meituan.com pinduoduo.com suning.com vip.com didiglobal.com cainiao.com
mi.com oppo.com vivo.com.cn meizu.com coloros.com edu.cn gov.cn 12306.cn"

# v3.4.53: 系统级保护 — 从所有规则中剔除保护域名 (精确 + 子域名后缀 + 关键段)
# 输入: stdin = 纯域名列表; 保护表 PROTECT_DOMAINS 全局变量
# 变量名用 seg 避开 awk 内置函数 sub() (同 filter_whitelist)
# 匹配三级: ① 精确 ② 后缀子域名 (qq.com 匹配 ad.qq.com) ③ 关键段 (PROTECT_SEGS 中段匹配)
# v3.4.60: 广告域名例外 — 先校验 AD_DOMAINS, 命中则直接放行到输出 (恢复屏蔽),
# 不进保护逻辑。修复酷安开屏广告: qq.com 整域保护连带放行了 gdt.qq.com 等广告域名。
filter_protect() {
  local pat
  pat=$(printf '%s' "$PROTECT_DOMAINS" | tr ' ' '\n' | grep -v '^$' | tr '\n' '|' | sed 's/|$//')
  local segs
  segs=$(printf '%s' "$PROTECT_SEGS" | tr ' ' '\n' | grep -v '^$' | tr '\n' '|' | sed 's/|$//')
  # v3.4.60: 广告域名表 → awk 数组 (精确 + 子域名后缀匹配)
  local ads
  ads=$(printf '%s' "$AD_DOMAINS" | tr ' ' '\n' | grep -v '^$' | tr '\n' '|' | sed 's/|$//')
  if [ -z "$pat" ] && [ -z "$segs" ]; then cat; return; fi
  # pat 为空时给占位, 避免 awk split 出空串
  [ -z "$pat" ] && pat='__none__'
  [ -z "$segs" ] && segs='__none__'
  [ -z "$ads" ] && ads='__none__'
  awk -v pat="$pat" -v segs="$segs" -v ads="$ads" '
    BEGIN {
      np = split(pat, P, "|"); for (i = 1; i <= np; i++) WL[P[i]] = 1
      ns = split(segs, S, "|"); for (i = 1; i <= ns; i++) SG[S[i]] = 1
      na = split(ads, AD, "|"); for (i = 1; i <= na; i++) ADM[AD[i]] = 1
    }
    {
      d = $0
      # v3.4.60: 广告域名优先 — 命中例外表直接输出 (恢复屏蔽), 跳过保护逻辑
      if (d in ADM) { print; next }
      n0 = split(d, pa, ".")
      for (k0 = 1; k0 < n0; k0++) {
        seg0 = ""
        for (j0 = k0; j0 <= n0; j0++) seg0 = seg0 (j0 > k0 ? "." : "") pa[j0]
        if (seg0 in ADM) { print; next }
      }
      if (d in WL) next
      # ② 后缀子域名: ad.qq.com 的任意后缀 = qq.com
      n = split(d, parts, ".")
      for (k = 1; k < n; k++) {
        seg = ""
        for (j = k; j <= n; j++) seg = seg (j > k ? "." : "") parts[j]
        if (seg in WL) { next }
      }
      # ③ 关键段: PROTECT_SEGS 出现在域名任意位置 (如 a13e300 在 io.github.a13e300.ksuwebui)
      for (i = 1; i <= ns; i++) if (index(d, S[i]) > 0) next
      print
    }
  ' 2>/dev/null
}

# v3.4.55: JSON 字符串转义 — 源名称等用户可编辑字段进 JSON 前必须转义
# (H1 修复: 规则源名称含 " 或 \ 会破坏 state/bench JSON)
json_escape() {
  printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g' | tr -d '\n\r\t' 2>/dev/null
}

# v3.4.55: JSON 安全过滤 — 拒绝双引号/反斜杠/控制字符, 只留可读字符
# 用于 fail_list/name/verdict 等短字段 (比 json_escape 更保守, 直接剔除非法字符)
json_sanitize() {
  printf '%s' "$1" | tr -d '"\\\n\r\t' 2>/dev/null | cut -c1-80
}

init_conf() {
  [ -f "$SRC_FILE" ] || printf '%s\n' "$DEFAULT_SOURCES" > "$SRC_FILE" 2>/dev/null
  [ -f "$WL_FILE" ] || printf '# 广告屏蔽白名单 — 每行一个域名, 允许其通过\n# 示例:\n#ads.example.com\n' > "$WL_FILE" 2>/dev/null
}

is_mounted() {
  awk '{print $2}' /proc/mounts 2>/dev/null | grep -qx "$SYS_HOSTS" && return 0
  return 1
}

# 域名提取 (从任意格式 hosts/域名列表中): 输入文件, 输出纯小写域名 (每行一个)
# 兼容三种格式: "0.0.0.0 domain" / "127.0.0.1 domain" / 纯 "domain"
# v3.4.55 (H2 修复): 优先取 $2 (hosts 格式的域名列), 不能是域名时回退 $NF
#   原 $NF 取最后一字段: "0.0.0.0 domain aliases" 取到 aliases (非域名)
#   现在先试 $2 (IP 后第一列 = 真域名), 校验失败再回退旧行为
extract_domains() {
  awk '
    # v3.4.53: 跳过注释行 — 原 /^[[:space:]]*#/ 只跳过行首注释,
    # 但 hblock 源含 "0.0.0.0 #[domain]" 格式: $NF 取到 "#[domain]" 这种伪域名
    /^[[:space:]]*#/ { next }
    /^[[:space:]]*$/ { next }
    {
      # v3.4.55 (H2): 首选 $2 (hosts 格式 "IP DOMAIN"), 纯域名列表 NF==1 时用 $1
      # $2 校验失败 (是 IP/注释残片) 才回退 $NF, 兼容所有历史格式
      if (NF >= 2 && $2 !~ /^[0-9.]+$/ && $2 !~ /#/ && $2 !~ /^$/) {
        d = tolower($2)
      } else {
        d = tolower($NF)
      }
      if (d == "localhost" || d == "ip6-localhost") next
      if (d ~ /^[0-9.]+$/) next
      if (d ~ /:/) next
      if (length(d) < 4) next
      if (d ~ /a13e300/) next
      # v3.4.53: 带 # 的注释残片 (如 "#[domain]" / "#comment") 不是域名
      if (d ~ /#/) next
      # v3.4.53: 方括号包裹的 hblock 特殊格式 "[domain]" 去括号
      if (d ~ /^\[.*\]$/) next
      # v3.4.53: 去前导点 — hosts 文件不认 ".example.com" (BIND 通配语法), 统一去点
      sub(/^\./, "", d)
      # v3.4.53: 单级/无效 TLD (".com" 去点后 = "com") 误伤风险极高, 跳过
      if (d !~ /\./) next
      # v3.4.53: 过长域名 (>253) 可能是数据损坏
      if (length(d) > 253) next
      # v3.4.63: 脏数据修复 — 规则源含 URL 路径/中文标点/其他非域名字符
      # 实测脏行: "en.wikipedia.org/wiki/..." (URL 路径进 hosts 会把整个域名屏蔽)
      #           "alisat.biz。" (中文句号, 后缀匹配失效致保护域名漏过滤)
      #           "mwave.com.au]" (hblock 残留方括号)
      # 只允许 [a-z0-9._-], 一次性拒绝所有非域名字符 (含 / : ? # [ ] 空格 全角符)
      if (d !~ /^[a-z0-9._-]+$/) next
      print d
    }
  ' "$1" 2>/dev/null
}

# 生成 hosts 文件 (输入: 纯域名列表, 每行一个域名)
make_hosts() {
  awk '{ printf "0.0.0.0 %s\n", $0 }' "$1" 2>/dev/null
}

# 剔除白名单 (输入: stdin 纯域名列表; $1 = 白名单模式; 子域名匹配)
# v3.4.53: 修历史 bug — 变量名 sub 与 awk 内置函数 sub() 冲突, 静默导致整个函数失效
filter_whitelist() {
  awk -v pat="$1" '
    BEGIN { np = split(pat, P, "|"); for (i = 1; i <= np; i++) WL[P[i]] = 1 }
    {
      d = $0
      if (d in WL) next
      n = split(d, parts, ".")
      for (k = 1; k < n; k++) {
        seg = ""
        for (j = k; j <= n; j++) seg = seg (j > k ? "." : "") parts[j]
        if (seg in WL) { next }
      }
      print
    }
  ' 2>/dev/null
}

# 构建白名单 awk 模式 (从 WL_FILE)
wl_pattern() {
  [ -s "$WL_FILE" ] || return 0
  local pat=''
  while IFS= read -r line; do
    line=$(printf '%s' "$line" | sed 's/[[:space:]]*$//; s/^[[:space:]]*//')
    [ -z "$line" ] && continue
    case "$line" in \#*) continue;; esac
    [ -z "$pat" ] && pat="$line" || pat="$pat|$line"
  done < "$WL_FILE"
  printf '%s' "$pat"
}

do_update() {
  init_conf
  mkdir -p "$TMP_DIR" 2>/dev/null || return 1
  local merged="$TMP_DIR/merged.txt"
  local src_count=0 ok_count=0 fail_list=''
  : > "$merged"
  # v3.4.54: 重置进度日志
  : > "$PROGRESS_FILE" 2>/dev/null
  log_progress "开始更新规则源"

  while IFS='|' read -r enabled name url; do
    [ -z "$enabled" ] && continue
    [ "$enabled" = "1" ] || continue
    src_count=$((src_count + 1))
    local out="$TMP_DIR/src_$src_count.txt"
    # v3.4.54: 进度 — 每个源下载前写一行
    log_progress "[$src_count] 下载 $name"
    # v3.4.53: curl 带重试 — 网络抖动不该让整个更新失败
    if curl -s -L --retry 3 --retry-delay 2 -m 120 -o "$out" "$url" 2>/dev/null && [ -s "$out" ]; then
      ok_count=$((ok_count + 1))
      local dl_lines
      dl_lines=$(wc -l < "$out" 2>/dev/null)
      log_progress "[$src_count] $name 下载成功 $dl_lines 行"
      extract_domains "$out" >> "$merged"
    else
      fail_list="$fail_list $name"
      log_progress "[$src_count] $name 下载失败"
    fi
  done < "$SRC_FILE"

  log_progress "下载完成: $ok_count/$src_count 个源成功"

  if [ "$ok_count" -eq 0 ]; then
    rm -rf "$TMP_DIR"
    # v3.4.55 (H1): fail_list 进 JSON 前先消毒 (源名称用户可编辑, 含 " \ 会破坏 state JSON)
    local fail_safe
    fail_safe=$(json_sanitize "$fail_list")
    write_state "{\"enabled\":0,\"error\":\"全部规则源下载失败\",\"failed\":\"$fail_safe\"}"
    log_progress "更新失败: 全部规则源下载失败"
    printf '{"error":"全部规则源下载失败","failed":"%s"}\n' "$fail_safe"
    return 1
  fi

  # 去重
  log_progress "去重中 (sort -u)..."
  local dedup="$TMP_DIR/dedup.txt"
  sort -u "$merged" > "$dedup" 2>/dev/null
  local dedup_lines
  dedup_lines=$(wc -l < "$dedup" 2>/dev/null)
  log_progress "去重完成: $dedup_lines 条"

  # v3.4.53: 系统级保护 — 剔除核心域名 (防规则源误伤微信/QQ/淘宝等常用 App)
  log_progress "保护域名过滤中 (防误伤)..."
  # v3.4.65: 规则瘦身 (修复历史 bug + 国内裁剪)
  # 原 bug: 瘦身 awk 检查 $2, 但此阶段数据是纯域名 (每行一个, 无 IP 前缀), $2 恒为空
  #         → 匹配永不命中 → 瘦身从未生效 (实测 hosts 里 cyou 10506 条 / cfd 7498 条未删)
  # 修复: 改检 $1; 且不再被 "filter_protect 输出为空" 的回退路径旁路 (原 311 行回退)
  # 新增: 国内场景裁剪 — 删除纯国际地理 TLD (fr/pl/br/de 等), 国内 App 永不访问
  log_progress "规则瘦身中 (修 bug + 国内裁剪)..."
  local protected="$TMP_DIR/protected.txt"
  filter_protect < "$dedup" > "$protected" 2>/dev/null
  [ -s "$protected" ] || cp "$dedup" "$protected" 2>/dev/null
  # v3.4.65: 垃圾尾缀 — 一次性域名/DNS 污染重灾区 (原 v3.4.62 列表)
  awk '$1 !~ /\.(cyou|lol|lat|mom|autos|pics|skin|hair|yt|tk|bond|buzz|baby|beer|pm|homes|science|business|cf|beauty|press|watch|gq|loan|review|sbs|monster|boats|onion|website|works|world|ws|xxx|yoga|zone|win|wiki)$/ {print}' "$protected" > "$protected.tmp" 2>/dev/null
  [ -s "$protected.tmp" ] && mv "$protected.tmp" "$protected"
  # v3.4.65: 纯国际地理 TLD — 国内 App 网络请求中几乎不出现, 删之
  # 保留: com/net/org/cn/io/ai/cc/me/info(商业化常用) 等全球通用与常用尾缀
  awk '$1 !~ /\.(fr|pl|br|de|ru|it|es|nl|se|no|fi|dk|at|ch|cz|gr|pt|hu|ro|bg|hr|si|sk|lt|lv|ee|cy|lu|mc|ad|li|is|mt|cat|gal|eus|bret|fr)$/ {print}' "$protected" 2>/dev/null > "$protected.tmp" 2>/dev/null
  [ -s "$protected.tmp" ] && mv "$protected.tmp" "$protected"
  local slim_lines
  slim_lines=$(wc -l < "$protected" 2>/dev/null)
  log_progress "瘦身完成: $slim_lines 条"
  # 剔除白名单
  log_progress "白名单过滤中..."
  local final="$TMP_DIR/final.txt"
  local pat=$(wl_pattern)
  if [ -n "$pat" ]; then
    filter_whitelist "$pat" < "$protected" > "$final" 2>/dev/null
  else
    cp "$protected" "$final" 2>/dev/null
  fi

  local total=0
  total=$(wc -l < "$final" 2>/dev/null)
  case "$total" in ''|*[!0-9]*) total=0;; esac
  log_progress "过滤完成: $total 条规则"

  log_progress "生成 hosts 文件..."
  make_hosts "$final" > "$HOSTS_FILE.tmp" 2>/dev/null
  [ -s "$HOSTS_FILE.tmp" ] && mv "$HOSTS_FILE.tmp" "$HOSTS_FILE" 2>/dev/null
  log_progress "hosts 文件已生成"

  local crash_snap=0
  if [ -f "/data/local/tmp/atria_status.json" ]; then
    crash_snap=$(grep -o '"count_24h":[0-9]*' /data/local/tmp/atria_status.json 2>/dev/null | head -1 | grep -o '[0-9]*')
    case "$crash_snap" in ''|*[!0-9]*) crash_snap=0;; esac
  fi

  # v3.4.55 (H1): sources_fail / best_source 进 JSON 前消毒
  local fail_safe='' best_safe=''
  fail_safe=$(json_sanitize "$(printf '%s' "$fail_list" | sed 's/^ //')")
  best_safe=$(json_sanitize "$best")

  local now=$(date +%s)
  local auto_mounted=0
  if is_mounted; then
    # 已挂载 → 重新挂载新文件 (umount + mount, 规则立即生效不重启)
    log_progress "重新挂载 hosts (规则立即生效)..."
    umount "$SYS_HOSTS" 2>/dev/null
    mount -o bind "$HOSTS_FILE" "$SYS_HOSTS" 2>/dev/null
    is_mounted && auto_mounted=1
  fi
  log_progress "挂载检查: auto_mounted=$auto_mounted"
  local best=''
  [ -f "$BENCH_FILE" ] && best=$(grep -o '"best_source":"[^"]*"' "$BENCH_FILE" 2>/dev/null | head -1 | sed 's/.*":"//; s/"$//')
  # v3.4.55 (H1): best_source 二次消毒 (bench 文件可能被外部篡改)
  best=$(json_sanitize "$best")

  write_state "{\"enabled\":1,\"hosts_count\":$total,\"sources_ok\":$ok_count,\"sources_fail\":\"$fail_safe\",\"updated_ts\":$now,\"crash_snap\":$crash_snap,\"auto_remount\":$auto_mounted,\"best_source\":\"$best_safe\",\"version\":\"$VERSION\"}"

  rm -rf "$TMP_DIR"
  log_progress "DONE 更新完成: $total 条规则, $ok_count 个源成功"
  printf '{"ok":true,"hosts_count":%d,"sources_ok":%d,"sources_fail":"%s","updated_ts":%d,"best_source":"%s"}\n' \
    "$total" "$ok_count" "$fail_safe" "$now" "$best_safe"
  return 0
}

do_apply() {
  [ -s "$HOSTS_FILE" ] || { printf '{"error":"hosts 文件为空, 请先 update"}\n'; return 1; }
  if is_mounted; then
    printf '{"ok":true,"msg":"already mounted","hosts_count":%d}\n' "$(wc -l < "$HOSTS_FILE" 2>/dev/null)"
    return 0
  fi
  mount -o bind "$HOSTS_FILE" "$SYS_HOSTS" 2>/dev/null
  if is_mounted; then
    printf '{"ok":true,"mounted":1,"hosts_count":%d}\n' "$(wc -l < "$HOSTS_FILE" 2>/dev/null)"
    return 0
  fi
  printf '{"error":"mount 失败 (权限或 SELinux)"}\n'
  return 1
}

do_unapply() {
  if ! is_mounted; then
    printf '{"ok":true,"msg":"not mounted"}\n'
    return 0
  fi
  umount "$SYS_HOSTS" 2>/dev/null
  is_mounted || { printf '{"ok":true,"unmounted":1}\n'; return 0; }
  umount -l "$SYS_HOSTS" 2>/dev/null
  is_mounted || { printf '{"ok":true,"unmounted":1}\n'; return 0; }
  printf '{"error":"umount 失败"}\n'
  return 1
}

write_state() { printf '%s\n' "$1" > "$STATE_FILE" 2>/dev/null; }

do_status() {
  local mounted=0
  is_mounted && mounted=1
  local hosts_lines=0
  [ -s "$HOSTS_FILE" ] && hosts_lines=$(wc -l < "$HOSTS_FILE" 2>/dev/null)
  case "$hosts_lines" in ''|*[!0-9]*) hosts_lines=0;; esac
  local st='""'
  [ -f "$STATE_FILE" ] && st=$(cat "$STATE_FILE" 2>/dev/null | tr -d '\n')
  # v3.4.62: hosts_count 也以实测为准 (手动清理 hosts 后 state 未更新)
  if [ "$hosts_lines" -gt 1000 ] 2>/dev/null; then
    st=$(printf '%s' "$st" | sed "s/\"hosts_count\":[0-9]*/\"hosts_count\":$hosts_lines/" 2>/dev/null)
  fi
  # 合并实时挂载状态 (state 文件里的 enabled 可能过时, 以实际 mount 为准)
  if [ "$mounted" = "1" ]; then
printf '%s' "$st" | sed 's/"enabled":[0-9]*/"enabled":1/' 2>/dev/null
  else
    printf '%s' "$st" | sed 's/"enabled":[0-9]*/"enabled":0/' 2>/dev/null
  fi
  printf '\n'
}

do_toggle() {
  local act="$1"
  if [ "$act" = "on" ]; then
    { [ -s "$HOSTS_FILE" ] || do_update >/dev/null 2>&1; } && do_apply
  elif [ "$act" = "off" ]; then
    do_unapply
  else
    if is_mounted; then do_unapply; else { [ -s "$HOSTS_FILE" ] || do_update >/dev/null 2>&1; } && do_apply; fi
  fi
}

# v3.4.53: 当前被屏蔽连接数 (连到 0.0.0.0 的 socket)
do_hit() {
  local n=0
  n=$(grep -c ' 0\.0\.0\.0:' /proc/net/tcp /proc/net/tcp6 2>/dev/null | awk -F: '{s+=$NF} END {print s+0}')
  case "$n" in ''|*[!0-9]*) n=0;; esac
  printf '{"blocked_conns":%d}\n' "$n"
}

# ============================================================
# v3.4.53: 规则源质量评估 (benchmark)
# ============================================================
# 评估每个启用源的五项指标, 加权评分, 自动推荐最优源:
#   1) 下载成功率与耗时  (20分) — 稳定性, 源挂了等于没有
#   2) 规则条数          (20分) — 覆盖面, 超过 25 万条扣分 (过臃肿解析慢)
#   3) 独有规则增量      (20分) — 只在该源出现的域名数, 越多越不可替代
#   4) 误伤风险          (30分) — 命中核心域名 (google/qq/微信/淘宝等) 每个 -5, 最重要
#   5) 格式规范性        (10分) — hosts=10, domains=8
# 输出 JSON 数组到 BENCH_FILE, 标记 best_source。
# do_update 把全部启用源合并; benchmark 结果用于面板展示与推荐。

do_benchmark() {
  init_conf
  mkdir -p "$TMP_DIR" 2>/dev/null || return 1
  local bench_dir="$TMP_DIR/bench"
  rm -rf "$bench_dir" 2>/dev/null
  mkdir -p "$bench_dir" 2>/dev/null
  local idx=0

  # ---- 阶段1: 逐源下载 + 提取域名 + 记录元数据 ----
  # v3.4.53: 网络抖动不计入质量分 — curl 带 3 次重试 (anti-AD 实测 38s 可下完, 但偶发 60s+ 超时)
  while IFS='|' read -r enabled name url; do
    [ -z "$enabled" ] && continue
    [ "$enabled" = "1" ] || continue
    idx=$((idx + 1))
    local file="$bench_dir/src_$idx.txt"
    local t0=$(date +%s 2>/dev/null)
    local dl_ok=0
    printf '%s|%s\n' "$name" "$url" > "$bench_dir/name_$idx.txt"
    # v3.4.53: --retry 3 网络层重试; -m 120 单次上限放宽 (大规则集 + 抖动)
    if curl -s -L --retry 3 --retry-delay 2 -m 120 -o "$file" "$url" 2>/dev/null && [ -s "$file" ]; then
      dl_ok=1
    fi
    local dl_time=$(( $(date +%s 2>/dev/null) - t0 ))
    [ "$dl_time" -lt 0 ] && dl_time=0
    printf '%s\n' "$dl_time" > "$bench_dir/time_$idx.txt"
    [ "$dl_ok" = "1" ] && touch "$bench_dir/ok_$idx.txt" 2>/dev/null

    if [ "$dl_ok" = "1" ]; then
      extract_domains "$file" | sort -u > "$bench_dir/dom_$idx.txt" 2>/dev/null
      # 格式: hosts 格式还是纯域名
      if head -50 "$file" 2>/dev/null | grep -qE '^[0-9.]+[[:space:]]+[a-z]'; then
        printf 'hosts\n' > "$bench_dir/fmt_$idx.txt"
      else
        printf 'domains\n' > "$bench_dir/fmt_$idx.txt"
      fi
    else
      : > "$bench_dir/dom_$idx.txt"
      : > "$bench_dir/fmt_$idx.txt"
    fi
  done < "$SRC_FILE"

  if [ "$idx" -eq 0 ]; then
    rm -rf "$TMP_DIR"
    printf '{"error":"无启用源"}\n'
    return 1
  fi

  # ---- 阶段2: 集合运算 (一个 awk 算全部源的独有数) ----
  # 域名编号: 域名 → 只在一个源出现 = 该源独有
  local stream=''
  local i
  for i in $(seq 1 $idx); do
    [ -f "$bench_dir/dom_$i.txt" ] || continue
    # 每行带来源编号 (排序后的文件, 同源内已去重)
    awk -v s="$i" '{printf "%s %d\n", $0, s}' "$bench_dir/dom_$i.txt" 2>/dev/null
  done > "$bench_dir/stream.txt"

  # 独有计数: 域名只归一个源 → 该源 unique+1
  awk '
    {
      d = $1; s = $2 + 0
      key = d SUBSEP s
      if (!(key in seen)) { seen[key] = 1; dn[d] = dn[d] " " s }
    }
    END {
      for (d in dn) {
        n = split(dn[d], a, " ")
        srcs = 0
        for (k = 1; k <= n; k++) if (a[k] != "") srcs++
        if (srcs == 1) {
          for (k = 1; k <= n; k++) if (a[k] != "") { uniq[a[k]]++; break }
        }
      }
      for (s = 1; s <= '"$idx"'; s++) printf "%d\n", uniq[s] + 0
    }
  ' "$bench_dir/stream.txt" 2>/dev/null > "$bench_dir/uniq.txt"

  # ---- 阶段3: 逐源评分 ----
  local results=''
  local best_name='' best_score=-1
  local best_url=''
  for i in $(seq 1 $idx); do
    local name=$(cut -d'|' -f1 "$bench_dir/name_$i.txt" 2>/dev/null)
    local url=$(cut -d'|' -f2 "$bench_dir/name_$i.txt" 2>/dev/null)
    local dl_time=$(cat "$bench_dir/time_$i.txt" 2>/dev/null)
    case "$dl_time" in ''|*[!0-9]*) dl_time=0;; esac
    local fmt=$(cat "$bench_dir/fmt_$i.txt" 2>/dev/null | tr -d '\n')
    local ok=0
    [ -f "$bench_dir/ok_$i.txt" ] && ok=1
    local count=0
    [ -f "$bench_dir/dom_$i.txt" ] && count=$(wc -l < "$bench_dir/dom_$i.txt" 2>/dev/null)
    case "$count" in ''|*[!0-9]*) count=0;; esac
    local uniq_cnt=$(sed -n "${i}p" "$bench_dir/uniq.txt" 2>/dev/null)
    case "$uniq_cnt" in ''|*[!0-9]*) uniq_cnt=0;; esac

    # 误伤检测: 该源命中几个核心域名
    local core_hit=0
    if [ "$ok" = "1" ] && [ -s "$bench_dir/dom_$i.txt" ]; then
      for cd in $CORE_DOMAINS; do
        local cd_esc=$(printf '%s' "$cd" | sed 's/\./\\./g')
        if grep -qE "(^|\.)([a-z0-9-]+\.)*${cd_esc}$" "$bench_dir/dom_$i.txt" 2>/dev/null; then
          core_hit=$((core_hit + 1))
        fi
      done
    fi

    # 评分
    local t_score=0 c_score=0 u_score=0 k_score=30 f_score=0
    if [ "$ok" = "1" ]; then
      t_score=15
      if [ "$dl_time" -le 30 ]; then t_score=20
      elif [ "$dl_time" -le 60 ]; then t_score=17
      elif [ "$dl_time" -le 90 ]; then t_score=14
      else t_score=12
      fi
    fi
    if [ "$count" -ge 50000 ]; then c_score=20
    elif [ "$count" -ge 10000 ]; then c_score=12
    elif [ "$count" -gt 0 ]; then c_score=6
    fi
    [ "$count" -gt 250000 ] && c_score=12
    if [ "$uniq_cnt" -ge 10000 ]; then u_score=20
    elif [ "$uniq_cnt" -ge 1000 ]; then u_score=12
    elif [ "$uniq_cnt" -gt 0 ]; then u_score=6
    fi
    k_score=$((30 - core_hit * 5))
    [ "$k_score" -lt 0 ] && k_score=0
    [ "$fmt" = "hosts" ] && f_score=10
    [ "$fmt" = "domains" ] && f_score=8
    local score=$((t_score + c_score + u_score + k_score + f_score))

    # 评语
    local verdict=''
    if [ "$ok" = "0" ]; then verdict='下载失败'
    elif [ "$core_hit" -gt 0 ]; then verdict="覆盖广但误伤${core_hit}个核心域名"
    elif [ "$score" -ge 85 ]; then verdict='推荐'
    elif [ "$score" -ge 65 ]; then verdict='良好'
    else verdict='一般'
    fi

    # v3.4.55 (H1): name/url/verdict 进 JSON 前消毒 — 源名称/URL 用户可编辑,
    # 含 " \ 会破坏 bench JSON, 前端解析失败整个评估结果不显示
    local name_safe url_safe verdict_safe
    name_safe=$(json_sanitize "$name")
    url_safe=$(json_sanitize "$url")
    verdict_safe=$(json_sanitize "$verdict")
    local entry="{\"name\":\"$name_safe\",\"url\":\"$url_safe\",\"dl_ok\":$ok,\"dl_time\":$dl_time,\"count\":$count,\"unique\":$uniq_cnt,\"core_hit\":$core_hit,\"fmt\":\"$fmt\",\"score\":$score,\"verdict\":\"$verdict_safe\"}"
    if [ -z "$results" ]; then results="$entry"; else results="$results,$entry"; fi

    if [ "$ok" = "1" ] && [ "$score" -gt "$best_score" ]; then
      best_score=$score
      best_name="$name_safe"
      best_url="$url_safe"
    fi
  done

  local now=$(date +%s 2>/dev/null)
  printf '{"ts":%d,"best_source":"%s","best_url":"%s","best_score":%d,"sources":[%s]}\n' \
    "$now" "$best_name" "$best_url" "$best_score" "$results" > "$BENCH_FILE" 2>/dev/null

  rm -rf "$TMP_DIR"
  printf '{"ok":true,"best_source":"%s","best_score":%d}\n' "$best_name" "$best_score"
  return 0
}

# v3.4.72: 开机自启 — service.sh 开机时调用本命令
# 逻辑: auto_start=1 且未挂载时自动 apply (hosts 文件在则秒级挂载, 不在则跳过不下载)
# auto_start=0 时什么都不做 (用户关了开关, 别打扰)
do_boot() {
  local auto_start=0
  if [ -f "$STATE_FILE" ]; then
    auto_start=$(grep -o '"auto_start":[0-9]*' "$STATE_FILE" 2>/dev/null | grep -o '[0-9]*$')
    case "$auto_start" in ''|*[!0-9]*) auto_start=0;; esac
  fi
  if [ "$auto_start" != "1" ]; then
    printf '{"ok":true,"skipped":1,"msg":"auto_start off"}\n'
    return 0
  fi
  if is_mounted; then
    printf '{"ok":true,"skipped":1,"msg":"already mounted"}\n'
    return 0
  fi
  # hosts 规则文件在 → 直接挂载; 不在 → 跳过 (开机时下载大文件会拖慢启动)
  if [ -s "$HOSTS_FILE" ]; then
    do_apply
  else
    printf '{"ok":true,"skipped":1,"msg":"hosts file empty, skip"}\n'
  fi
}

# ============================================================
# 主入口
# ============================================================
case "$1" in
  update)     do_update ;;
  apply)      do_apply ;;
  unapply)    do_unapply ;;
  status)     do_status ;;
  toggle)     do_toggle "$2" ;;
  benchmark)  do_benchmark ;;
  hit)        do_hit ;;
  boot)       do_boot ;;

# v3.4.72: 开机自启开关 — setauto on|off, 写 state 文件的 auto_start 字段
# v3.4.73: 重写为 sed 原地改, 不再「读→合并→写回」(旧法在 state 缺字段时塌缩成 2 字段)
setauto)
  _v="$2"
  case "$_v" in
    on|1) _v=1 ;;
    off|0) _v=0 ;;
    *) printf '{"error":"用法: setauto on|off"}\n'; exit 1 ;;
  esac
  # state 不存在 → 创建完整默认 state (含全部 9 字段)
  if [ ! -f "$STATE_FILE" ]; then
    write_state "{\"enabled\":0,\"hosts_count\":0,\"sources_ok\":0,\"sources_fail\":\"\",\"updated_ts\":0,\"crash_snap\":0,\"auto_remount\":0,\"best_source\":\"\",\"auto_start\":$_v,\"version\":\"$VERSION\"}"
  else
    # 原地改: 有 auto_start → sed 替换; 没有 → 剥尾 } 追加 (只动 auto_start, 其余字段原样保留)
    if grep -q '"auto_start"' "$STATE_FILE" 2>/dev/null; then
      sed -i "s/\"auto_start\":[0-9]*/\"auto_start\":$_v/" "$STATE_FILE" 2>/dev/null
    else
      sed -i "s/}$/,\"auto_start\":$_v}/" "$STATE_FILE" 2>/dev/null
    fi
  fi
  printf '{"ok":true,"auto_start":%d}\n' "$_v"
  ;;
# v3.4.54: 后台更新 — setsid 脱离父进程, 不被 WebView exec 桥会话结束杀死
# 前端点击"更新规则"后立即返回, 边写进度日志边让前端轮询
# 注意: 必须用 sh -c 包裹再 setsid 执行脚本自身 — 直接 setsid do_update 不会启动
update-bg)
  setsid sh "$0" update < /dev/null > /dev/null 2>&1 &
  printf '{"ok":true,"bg":true,"msg":"后台更新已启动"}\n'
  ;;
# v3.4.54: 读更新进度日志 (前端轮询用)
progress)
  if [ -f "$PROGRESS_FILE" ]; then
    cat "$PROGRESS_FILE" 2>/dev/null
  else
    printf '[0] 无更新任务\n'
  fi
  ;;
  *)
    printf '用法: adblock.sh {update|update-bg|progress|apply|unapply|status|toggle|benchmark|hit}\n'
    exit 1
    ;;
esac