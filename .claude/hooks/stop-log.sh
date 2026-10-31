#!/bin/bash
# ============================================================
# Hook: Stop
# 作用: 每当 Claude 主会话「停下来等用户」时,在本地追加一行运行记录,
#       方便课后回看「这一周跑了几次、各次状态」。
#       注意: Stop 在每次 Claude 回完消息时都会触发,不是只有 weekly-monitor 跑完。
#       所以本 hook 只在「检测到本周 _changes.md 已存在且较新」时才记一行,
#       避免日志被普通对话刷屏。
#
# 触发事件: Stop
# 输入: stdin JSON,字段含 stop_hook_active(防止 Stop 反复触发的标志)
# 退出码:
#   0 → 正常,Claude 自然停下
#   2 → 强制 Claude 继续工作(本 hook 永远不要返回 2,否则会无限循环)
# ============================================================

set -e
cd "${CLAUDE_PROJECT_DIR:-.}"
export PYTHONIOENCODING=utf-8

# 加载共享日志
source "$(dirname "$0")/_log-helper.sh"

# ---------- 防止 Stop 无限循环 ----------
INPUT=$(cat)
STOP_ACTIVE=$(echo "$INPUT" | python -c "
import json, sys
try:
    data = json.load(sys.stdin)
    print('true' if data.get('stop_hook_active') else 'false')
except Exception:
    print('false')
")
if [ "$STOP_ACTIVE" = "true" ]; then
  # 已经是被 hook 强制延续的回合,无脑放过
  exit 0
fi

# ---------- 仅在「这次会话产出了 _changes.md」时记日志 ----------
CHANGES_FILE="reports/current/_changes.md"
if [ ! -f "$CHANGES_FILE" ]; then
  hook_log "stop" "INFO" "会话结束(非巡检会话)"
  exit 0  # 不是巡检会话,别记
fi

# 文件 60 秒内被改过,才认为是「这次会话刚跑完」
NOW=$(date +%s)
MTIME=$(stat -c %Y "$CHANGES_FILE" 2>/dev/null || stat -f %m "$CHANGES_FILE" 2>/dev/null || echo 0)
DELTA=$((NOW - MTIME))
if [ "$DELTA" -gt 60 ]; then
  hook_log "stop" "INFO" "会话结束(_changes.md 非本次产出)"
  exit 0
fi

# ---------- 提取本次跑的简要数据 ----------
# 用 awk 按段落统计,避免在「无变化」段里描述升级时的句子被误数
WEEK=$(date +%Y-W%V)
URGENT=$(awk '/^## .*🔺 升级|^## .*🔴 (新增高风险|升级)/{f=1;next} /^## /{f=0} f && /^- \*\*/' "$CHANGES_FILE" 2>/dev/null | wc -l | tr -d ' ')
NORMAL=$(awk '/^## .*➕ 风险新增|^## .*🔻 降级|^## .*➖ 风险解除|^## .*🟡 风险新增|^## .*🟡 风险升级|^## .*🟢 (低风险|风险解除)/{f=1;next} /^## /{f=0} f && /^- \*\*/' "$CHANGES_FILE" 2>/dev/null | wc -l | tr -d ' ')

mkdir -p .claude
LOG_FILE=".claude/run.log"

# ---------- 追加一行 ----------
hook_log "stop" "INFO" "巡检完成 week=${WEEK} urgent=${URGENT} normal=${NORMAL}"

{
  printf '%s | week=%s | urgent=%s | normal=%s\n' \
    "$(date '+%Y-%m-%d %H:%M:%S')" "$WEEK" "$URGENT" "$NORMAL"
} >> "$LOG_FILE"

# 保留最近 200 行,防止日志无限膨胀
if [ "$(wc -l < "$LOG_FILE" 2>/dev/null || echo 0)" -gt 200 ]; then
  tail -n 200 "$LOG_FILE" > "${LOG_FILE}.tmp" && mv "${LOG_FILE}.tmp" "$LOG_FILE"
fi

exit 0
