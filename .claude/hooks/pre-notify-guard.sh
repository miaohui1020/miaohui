#!/bin/bash
# ============================================================
# Hook: PreToolUse(matcher: Bash)
# 作用: 在 Claude 即将执行 notify/send-*.sh 之前做最后一道体检,
#       防止「空消息」「没有等级标识的消息」被推到群里给业务方添堵。
#       这是少数应该用 exit 2(硬拦)的场景: 一旦发出去就追不回来。
#
# 触发事件: PreToolUse,matcher 为 Bash(在 settings.json 里筛掉 notify/ 之外的)
# 输入: stdin JSON,字段 tool_input.command 是即将执行的 shell 命令
# 退出码:
#   0 → 放行
#   2 → 阻止执行,stderr 内容会被 Claude 看到,它会理解「为什么被拦」并自动修正
# ============================================================

set -e
cd "${CLAUDE_PROJECT_DIR:-.}"

# 加载共享日志
source "$(dirname "$0")/_log-helper.sh"

# ---------- 解析即将执行的 command ----------
INPUT=$(cat)
CMD=$(echo "$INPUT" | python -c "
import json, sys
try:
    data = json.load(sys.stdin)
    print(data.get('tool_input', {}).get('command', ''))
except Exception:
    print('')
")

# 只关心 notify/send-* 这条命令,其他 Bash 调用一律放行
case "$CMD" in
  *notify/send-dingtalk.sh*|*notify/send-feishu.sh*)
    : # 继续检查
    ;;
  *)
    exit 0
    ;;
esac

hook_log "pre-notify-guard" "INFO" "检测到推送命令: $(echo "$CMD" | head -c 80)"

# ---------- 提取要推送的文件路径 ----------
# 命令格式形如: bash notify/send-feishu.sh urgent reports/current/_changes.md
# 用 awk 取最后一个非空 token
TARGET=$(echo "$CMD" | awk '{print $NF}')

# 如果 TARGET 不像文件路径,反而像命令尾巴的引号 / pipe,就跳过这一步检查
if [ -z "$TARGET" ] || [ "${TARGET:0:1}" = "|" ] || [ "${TARGET:0:1}" = "&" ]; then
  exit 0
fi

# ---------- 防呆 1:文件必须存在 ----------
if [ ! -f "$TARGET" ]; then
  hook_log "pre-notify-guard" "BLOCK" "文件不存在: $TARGET"
  echo "🛡️ pre-notify-guard 拦截: 推送目标文件不存在 -> $TARGET" >&2
  echo "建议: 确认 _changes.md 已由 change-detector 写入,或检查路径是否打错" >&2
  exit 2
fi

# ---------- 防呆 2:文件不能为空 / 太短 ----------
SIZE=$(wc -c < "$TARGET" | tr -d ' ')
if [ "$SIZE" -lt 80 ]; then
  hook_log "pre-notify-guard" "BLOCK" "内容过短(${SIZE}B): $TARGET"
  echo "🛡️ pre-notify-guard 拦截: 推送内容过短(${SIZE} 字节),疑似空模板" >&2
  echo "推送目标: $TARGET" >&2
  echo "建议: 先确认报告是否真有内容,空模板别推到群里" >&2
  exit 2
fi

# ---------- 防呆 3:_changes.md 必须含至少一个等级标识 ----------
# (避免推一份「干干净净没结论」的报告出去)
if echo "$TARGET" | grep -q "_changes.md"; then
  if ! grep -qE '🟢|🟡|🔴|🔺|🔻|➕|➖|⚪|首次基线' "$TARGET"; then
    hook_log "pre-notify-guard" "BLOCK" "无风险等级标识: $TARGET"
    echo "🛡️ pre-notify-guard 拦截: _changes.md 中没有任何风险等级标识" >&2
    echo "推送目标: $TARGET" >&2
    echo "建议: change-detector 应至少标记一类变化或写「首次基线」" >&2
    exit 2
  fi
fi

# 全部通过
hook_log "pre-notify-guard" "PASS" "推送放行: $TARGET"
exit 0
