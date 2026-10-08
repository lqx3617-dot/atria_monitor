#!/system/bin/sh
# Atria Monitor v3.4.53 - Install-time risk scanner
# Scans a newly installed package for lockscreen/trojan permission combos.
# Pipeline: pkg name -> dumpsys package -> heuristic scoring -> action
# v3.4.35 fix: BIND_ACCESSIBILITY_SERVICE / DEVICE_ADMIN live in the Service/Receiver
# declaration sections, NOT in requested permissions. Scan the full dump for them.
# Honest limits:
#   1) Android forbids third-party blocking of the install itself; this is "freeze after install"
#   2) logcat events may be lost; inject_install_fallback does pm list diff every 60s
#   3) no virus DB; pure permission-combo heuristics, not a substitute for an AV
PATH=/system/bin:/system/xbin:/sbin:/vendor/bin:$PATH

LOG=/data/local/tmp/atria_install_log.jsonl
BASELINE=/data/local/tmp/atria_sec_baseline.txt

# whitelist: system + protected apps
is_sys_pkg() {
  case "$1" in
    com.android.*|com.google.*|com.miui.*|android.*) return 0 ;;
    com.ai.assistance.operit|com.iflytek.inputmethod) return 0 ;;
    *) return 1 ;;
  esac
}

scan_pkg() {
  SP_PKG="$1"
  case "$SP_PKG" in ''|*[!a-zA-Z0-9._-]*) return 1 ;; esac

  # v3.4.35: command substitution truncates large dumpsys output on this platform
  # (4543-line dump comes back empty inside $()). Write to a temp file instead.
  TMPDUMP=/tmp/.is_dump_$$.txt
  dumpsys package "$SP_PKG" 2>/dev/null > "$TMPDUMP"

  # true system package? (anti-spoof: com.android.* but installed on /data)
  SYS_PARTITION=1
  APKPATH=$(pm path "$SP_PKG" 2>/dev/null | head -1 | cut -d: -f2)
  case "$APKPATH" in
    /system/*|/system_ext/*|/vendor/*|/product/*) ;;
    *) SYS_PARTITION=0 ;;
  esac

  # installer of record
  INSTALLER=$(grep -m1 'installerPackageName=' "$TMPDUMP" 2>/dev/null | sed 's/.*installerPackageName=//; s/[^a-zA-Z0-9._-]//g')

  # v3.4.35: system packages get a fast path - they are trusted by definition and
  # their requested-perms list is huge (settings has 200+), which overflows printf
  if [ "$SYS_PARTITION" = "1" ] && is_sys_pkg "$SP_PKG"; then
    printf '%s\n' "{\"ts\":$(date +%s),\"pkg\":\"$SP_PKG\",\"score\":0,\"level\":\"low\",\"action\":\"pass\",\"acc\":0,\"da\":0,\"sys_partition\":1,\"installer\":\"$INSTALLER\",\"reasons\":\"\",\"perms\":\"\",\"detail\":\"system package, fast path\"}"
    rm -f "$TMPDUMP"
    return 0
  fi

  # requested permissions (ordinary perms like SMS, overlay)
  PERMS=$(sed -n '/requested permissions:/,/install permissions:/p' "$TMPDUMP" 2>/dev/null | awk '/^      [a-zA-Z]/{print}' | tr -d ' \r' | sort -u)

  # v3.4.35: lockscreen signals live in Service/Receiver declarations, not requested perms
  ACC=0
  grep -q 'permission android.permission.BIND_ACCESSIBILITY_SERVICE' "$TMPDUMP" 2>/dev/null && ACC=1
  DA=0
  grep -q 'android.app.action.DEVICE_ADMIN_ENABLED' "$TMPDUMP" 2>/dev/null && DA=1

  SCORE=0
  REASONS=''
  add_reason() { REASONS="${REASONS}${1}@${2};"; SCORE=$((SCORE + $2)); }
  has_perm() { printf '%s' "$PERMS" | grep -qx "$1"; }

  # 1. package-name spoofing (com.android.* but not on a system partition)
  case "$SP_PKG" in
    com.android.*)
      if [ "$SYS_PARTITION" = "0" ]; then add_reason 'PKG_SPOOF' 60; fi
      ;;
  esac

  # 2. lockscreen prime signal: accessibility service on a non-system package
  if [ "$ACC" = "1" ] && [ "$SYS_PARTITION" = "0" ]; then
    add_reason 'ACCESSIBILITY_NONSYS' 40
  fi

  # 3. lockscreen second signal: device admin receiver on a non-system package
  if [ "$DA" = "1" ] && [ "$SYS_PARTITION" = "0" ]; then
    add_reason 'DEVICE_ADMIN_NONSYS' 40
  fi

  # 4. overlay + lock combo
  if has_perm 'SYSTEM_ALERT_WINDOW'; then
    if [ "$ACC" = "1" ] || [ "$DA" = "1" ]; then
      add_reason 'OVERLAY_LOCK_COMBO' 25
    fi
  fi

  # 5. notification listener (reads notifications, can grab SMS codes)
  if has_perm 'BIND_NOTIFICATION_LISTENER_SERVICE'; then
    add_reason 'NOTIF_LISTENER' 20
  fi

  # 6. SMS theft
  if has_perm 'READ_SMS' || has_perm 'RECEIVE_SMS'; then
    add_reason 'SMS_ACCESS' 20
  fi

  # 7. accessibility + SMS = top-tier SMS-trojan combo
  if [ "$ACC" = "1" ]; then
    if has_perm 'READ_SMS' || has_perm 'RECEIVE_SMS'; then
      add_reason 'ACCESSIBILITY_SMS_COMBO' 30
    fi
  fi

  # 8. silent reinstall
  if has_perm 'REQUEST_INSTALL_PACKAGES' && [ "$SYS_PARTITION" = "0" ]; then
    add_reason 'REQUEST_INSTALL' 10
  fi

  LEVEL='low'
  [ "$SCORE" -ge 20 ] && [ "$SCORE" -lt 60 ] && LEVEL='med'
  [ "$SCORE" -ge 60 ] && LEVEL='high'

  TS=$(date +%s)

  ACTION='none'
  DETAIL=''
  if [ "$LEVEL" = 'high' ]; then
    if is_sys_pkg "$SP_PKG"; then
      ACTION='alert_only'; DETAIL='in whitelist, alert only'
    else
      if pm disable-user "$SP_PKG" >/dev/null 2>&1; then
        ACTION='frozen'; DETAIL='auto-frozen by pm disable-user'
      else
        ACTION='freeze_failed'; DETAIL='pm disable-user failed'
      fi
    fi
  elif [ "$LEVEL" = 'med' ]; then
    ACTION='alert_only'; DETAIL='medium risk, alert only'
  else
    ACTION='pass'; DETAIL='low risk'
  fi

  ESC_PERMS=$(printf '%s' "$PERMS" | tr '\n' ',' | sed 's/,$//; s/"/ /g' | cut -c1-100)
  rm -f "$TMPDUMP"
  printf '%s\n' "{\"ts\":$TS,\"pkg\":\"$SP_PKG\",\"score\":$SCORE,\"level\":\"$LEVEL\",\"action\":\"$ACTION\",\"acc\":$ACC,\"da\":$DA,\"sys_partition\":$SYS_PARTITION,\"installer\":\"$INSTALLER\",\"reasons\":\"$REASONS\",\"perms\":\"$ESC_PERMS\",\"detail\":\"$DETAIL\"}"
}

case "$1" in
  scan)
    scan_pkg "$2"
    ;;
  baseline)
    pm list packages 2>/dev/null | sed 's/^package://; s/\r$//' | sort > "$BASELINE"
    echo "baseline updated: $(wc -l < "$BASELINE") packages"
    ;;
  log)
    N=10
    [ -n "$2" ] && N="$2"
    tail -n "$N" "$LOG" 2>/dev/null
    ;;
  clear)
    : > "$LOG"
    echo "log cleared"
    ;;
  *)
    echo "usage: install_scan.sh scan <pkg> | baseline | log [n] | clear"
    echo "  scan <pkg>     scan one package for install-time risk"
    echo "  baseline       rebuild package baseline"
    echo "  log [n]        show last n install events"
    echo "  clear          clear install log"
    ;;
esac