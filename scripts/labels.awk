{
  # v3.4.39 labels sidecar 提取器 — 从 atriA_labels.conf 生成 JSON
  # 每行: 包名<TAB>应用名, 输出: "pkg":"label" 对
  FS = "\t"
  k = $1; v = $2
  if (k == "" || v == "") next
  if (k !~ /^[A-Za-z0-9._-]+$/) next
  # JSON 转义: \ -> \\, " -> \"
  gsub(/\\/, "\\\\", v)
  gsub(/"/, "\\\"", v)
  gsub(/[\n\r\t]/, " ", v)
  if (out != "") out = out ","
  out = out "\042" k "\042:\042" v "\042"
}
END { if (out != "") print out }