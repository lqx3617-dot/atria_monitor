# v3.4.62: 字符串感知的 JSON 括号平衡校验
# 旧实现 tr -cd '{' | wc -c 把引号内的括号也算进去 — logcat 消息常含 {xxx}
# (Android 日志格式), JSON 字符串值里的括号本就合法, 导致约 1.25% 采样被误杀。
# 本计数器逐字符扫描, 只统计双引号字符串字面量之外的 { }, 并处理 \" 转义。
# 输出: 一行整数, 0 = 平衡
BEGIN { bal = 0; instr = 0; esc = 0 }
{
  n = length($0)
  for (i = 1; i <= n; i++) {
    c = substr($0, i, 1)
    if (esc) { esc = 0; continue }
    if (c == "\\") { esc = 1; continue }
    if (instr) {
      if (c == "\"") instr = 0
      continue
    }
    if (c == "\"") { instr = 1; continue }
    if (c == "{") bal++
    else if (c == "}") bal--
  }
}
END { printf "%d\n", bal }
