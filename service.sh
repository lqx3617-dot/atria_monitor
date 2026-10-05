#!/system/bin/sh
# Atria Monitor v3.4.34 - 开机自启服务
# v3.2.36: 白名单应用图标提取 (刷新检测由 collect_loop.sh refresh_icons 负责)
# v3.2.34: 启动环境兼容 (KernelSU late_service 阶段 PATH 可能残缺, 补全常用路径)
export PATH=/system/bin:/system/xbin:/sbin:/vendor/bin:$PATH
# v3.1.1: 单例锁 + 日志轮转, 防止重复拉起与日志无限增长
# v3.1.2: 修复模块列表为空 + 流畅度优化 (2s采样 + diff渲染 + 告警去重)
# v3.1.3: AI 诊断自动优化 (一键优化 + AI actions 白名单执行 + 高风险自动修复)
# v3.1.4: 性能优化 (render DOM 写入守卫 + 网格离屏缓存 + 启动并行化 + 配置缓存)
# v3.1.5: AI 配置持久化 (模块目录外存储 + 旧配置自动迁移)
# v3.1.6: UI 美化 (玻璃拟态卡片 + 渐变标题 + 统一按钮 + 弹窗动画)
# v3.1.7: 性能优化 (移除 backdrop-filter 模糊 + 首屏渲染减负 + 弹窗期暂停轮询 + 请求防重入)
# v3.1.8: 采集重写 (logcat/ps/mods 单遍 awk + cpu_prev 防污染 + JSON 元素括号修复, 采集约 300ms + 状态 JSON 严格合法)
# v3.1.9: 安全与稳定性修复
#   - JSON 转义重写 (v3.1.8 gsub 反斜杠转义为空操作, 含 \ 的日志破坏整个 JSON)
#   - 模块启用态修复 (disable 路径缺斜杠导致恒为 true)
#   - 一键优化保护重写 (comm 截断导致 SystemUI/桌面被误杀)
#   - AI 配置注入修复 (base_url/api_key 未转义拼进 root 命令)
#   - 单例锁校验进程身份 (v3.1.8 仅查 PID 存活, PID 复用导致采集永不启动)
MODDIR=${0%/*}
LOCK=/data/local/tmp/atria_monitor.lock
LOG=/data/local/tmp/atria_monitor.log

# v3.1.9: 单例检查升级 - 锁内 PID 存活时还需确认它确实是 collect_loop,
# 避免 PID 复用 (开机后旧 PID 被新进程占用) 导致采集永不启动
if [ -r "$LOCK" ]; then
  OPID=$(cat "$LOCK" 2>/dev/null)
  case "$OPID" in ''|*[!0-9]*) ;; *)
    if [ -d /proc/"$OPID" ]; then
      if grep -q collect_loop /proc/"$OPID"/cmdline 2>/dev/null; then
        exit 0
      fi
    fi
    ;;
  esac
fi

# 日志轮转: 保留上一份, 防止反复重启导致日志膨胀
[ -f "$LOG" ] && mv "$LOG" "$LOG.old" 2>/dev/null

# v3.2.34: setsid 脱离父进程组, 防止 init/zygote 重启周期清理后台进程
# (原 nohup & 在部分 KernelSU/SukiSU 环境被杀, 表现为日志文件完全不生成)
if command -v setsid >/dev/null 2>&1; then
  setsid nohup sh "$MODDIR/scripts/collect_loop.sh" >> "$LOG" 2>&1 &
else
  nohup sh "$MODDIR/scripts/collect_loop.sh" >> "$LOG" 2>&1 &
fi
# v3.2.34: 不再写锁. setsid/nohup 后 $! 是父进程 PID (setsid 会 fork), 不可靠.
# 锁由 collect_loop.sh 自己写入 (echo $$ > $LOCK), 避免锁内 PID 指向已退出的 setsid
# v3.2.34: 启动自检 (3 秒后确认锁内 PID 存活且为 collect_loop, 失败则重试)
# 修复: 原实现 LOCK 为空时路径变成 /proc/ 恒存在, 永远误报"启动成功"
(sleep 3
  OPID=$(cat "$LOCK" 2>/dev/null)
  case "$OPID" in ''|*[!0-9]*)
    echo "[service] LOCK 为空或非法, 采集未启动, 尝试直接执行" >> "$LOG"
    sh "$MODDIR/scripts/collect_loop.sh" >> "$LOG" 2>&1 &
    echo $! > "$LOCK" 2>/dev/null
    exit 0
    ;;
  esac
  if [ -d /proc/"$OPID" ] && grep -q collect_loop /proc/"$OPID"/cmdline 2>/dev/null; then
    echo "[service] collect_loop 启动成功 PID $OPID" >> "$LOG"
  else
    echo "[service] collect_loop 启动失败 (PID $OPID 异常)! 尝试直接执行" >> "$LOG"
    sh "$MODDIR/scripts/collect_loop.sh" >> "$LOG" 2>&1 &
    echo $! > "$LOCK" 2>/dev/null
  fi) 2>/dev/null &