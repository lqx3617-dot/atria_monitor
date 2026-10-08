#!/system/bin/sh
# Atria Monitor v3.4.53 - install event watcher (daemon)
# watches logcat for PackageManager install events, feeds new packages to install_scan.sh
# singleton lock with PID+cmdline identity check (same as service.sh)
# fallback: even if this process is killed, inject_install_fallback in collect_loop does pm list diff every 60s
PATH=/system/bin:/system/xbin:/sbin:/vendor/bin:$PATH

DIR=$(dirname "$0")
LOCK=/data/local/tmp/atria_install_watch.lock
LOG=/data/local/tmp/atria_install_log.jsonl
# v3.4.53: STATE 变量已删 (死变量, 无引用); dedup 逻辑读 jsonl 日志尾部, 不需要 state 文件

if [ -r "$LOCK" ]; then
  OPID=$(cat "$LOCK" 2>/dev/null)
  case "$OPID" in ''|*[!0-9]*) ;; *)
    if [ -d /proc/"$OPID" ] && grep -q install_watch /proc/"$OPID"/cmdline 2>/dev/null; then
      exit 0
    fi
    ;;
  esac
fi
echo $$ > "$LOCK"

:

# v3.4.28 lesson: a long-lived pipe_read can hang the collector. use timeout-wrapped
# `logcat -d` batches + sleep polling; never block on a pipe forever
while true; do
  timeout 8 logcat -d 2>/dev/null > /tmp/.iw_log_$$.txt
  if [ -s /tmp/.iw_log_$$.txt ]; then
    # v3.4.35: logcat 是环形 buffer, 行号游标不可靠 (总行数会缩小)
    # 改为每轮全量扫 + 时间窗口去重 (5 分钟内同包不重复扫)
    grep -E 'uploadInstallAppInfos|Package Added|New package' /tmp/.iw_log_$$.txt 2>/dev/null | grep -oE 'app_pkg=[a-zA-Z0-9._]+' | sed 's/app_pkg=//' | tail -30 | while IFS= read -r LINE; do
        [ -z "$LINE" ] && continue
        PKG=$LINE
        case "$PKG" in
          ''|*[!a-zA-Z0-9._-]*) continue ;;
        esac
        NOW=$(date +%s)
        RECENT=0
        if [ -f "$LOG" ]; then
          LAST=$(tail -40 "$LOG" 2>/dev/null | grep "\"pkg\":\"$PKG\"" | tail -1 | grep -oE '"ts":[0-9]+' | cut -d: -f2)
          if [ -n "$LAST" ] && [ $((NOW - LAST)) -lt 300 ]; then RECENT=1; fi
        fi
        [ "$RECENT" = "1" ] && continue
        RESULT=$(sh "$DIR/install_scan.sh" scan "$PKG" 2>/dev/null)
        if [ -n "$RESULT" ]; then
          printf '%s\n' "$RESULT" >> "$LOG"
        fi
      done
  fi
  rm -f /tmp/.iw_log_$$.txt /tmp/.iw_new_$$.txt
  sleep 5
done