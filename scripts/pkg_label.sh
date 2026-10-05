#!/system/bin/sh
# v3.4.20 应用名提取器 — 从 launcher 桌面图标提取 title (应用名)
# 用法: pkg_label.sh [包名 ...]  不传则缓存全部到 /data/local/tmp/atria_labels.conf
CACHE=/data/local/tmp/atria_labels.conf
su -c 'dumpsys activity launcher' 2>/dev/null > /tmp/.ld_$$.txt
if [ ! -s /tmp/.ld_$$.txt ]; then echo "NO_LAUNCHER_DUMP"; rm -f /tmp/.ld_$$.txt; exit 1; fi
awk '
  {
    if (match($0, /ComponentInfo\{[A-Za-z0-9._]+\/[A-Za-z0-9._$]+\}/)) {
      s = substr($0, RSTART, RLENGTH)
      gsub(/ComponentInfo\{|\}/, "", s)
      split(s, a, "/")
      curpkg = a[1]
    }
    if (match($0, /title=[^,}]+/)) {
      t = substr($0, RSTART + 6, RLENGTH - 6)
      gsub(/[ \t]+$/, "", t)
      if (curpkg != "" && t != "") {
        key = curpkg SUBSEP t
        if (!(key in seen)) { seen[key] = 1; print curpkg "\t" t }
        curpkg = ""
      }
    }
  }
' /tmp/.ld_$$.txt | sort -u > "$CACHE"
rm -f /tmp/.ld_$$.txt
WC=$(wc -l < "$CACHE" 2>/dev/null)
if [ $# -gt 0 ]; then
  for PKG in "$@"; do
    # v3.4.34: 包名白名单校验 — grep 模式注入防御 (标签文件可被第三方应用写入)
    case "$PKG" in ''|*[!a-zA-Z0-9._-]*) echo "$PKG	-"; continue ;; esac
    L=$(grep -m1 "^$PKG	" "$CACHE" 2>/dev/null | cut -f2)
    if [ -n "$L" ]; then echo "$PKG	$L"; else echo "$PKG	-"; fi
  done
else
  echo "cached $WC labels to $CACHE"
fi