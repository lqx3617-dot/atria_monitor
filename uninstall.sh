#!/system/bin/sh
# Atria Monitor v3.4.88 - 卸载清理
LOCK=/data/local/tmp/atria_monitor.lock
OUT=/data/local/tmp/atria_status.json

# 先按锁内 PID 停止采集循环, 再兜底 pkill
if [ -r "$LOCK" ]; then
  OPID=$(cat "$LOCK" 2>/dev/null)
  [ -n "$OPID" ] && kill "$OPID" 2>/dev/null
fi
# v3.1.9: pkill -f 匹配完整路径, 避免误杀命令行恰好含该串的无关进程
pkill -f "atria_monitor/scripts/collect_loop" 2>/dev/null
pkill -f "atria_monitor/scripts/collect" 2>/dev/null

rm -f "$OUT" "$OUT.new" "$OUT.old" \
  /data/local/tmp/atria_monitor.log /data/local/tmp/atria_monitor.log.old \
  /data/local/tmp/atria_cpu_prev /data/local/tmp/atria_mods.awk \
  /data/local/tmp/atria_opt_res.txt /data/local/tmp/atria_opt_cnt.txt \
  /data/local/tmp/atria_opt_killed.txt "$LOCK"
# v3.2.5: 清理历史数据
rm -f /data/adb/atria_history.jsonl /data/adb/atria_mods.awk 2>/dev/null
rm -rf /data/local/tmp/atria_tmp 2>/dev/null
# v3.2.36: 清理应用图标目录 (WebView 可读, 故放 /data/local/tmp)
rm -rf /data/local/tmp/atria_icons 2>/dev/null

echo "Atria Monitor v3.4.84 已卸载"