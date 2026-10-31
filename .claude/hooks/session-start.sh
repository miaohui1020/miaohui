#!/bin/bash
# ============================================================
# Hook: SessionStart
# 作用: 每次进入 Claude Code 会话(start/resume/clear)时,
#       把「项目当前状态」作为 additionalContext 注入到模型上下文,
#       让 Claude 一进来就知道:上次跑过没?reports/ 里有没有数据?
#
# 触发事件: SessionStart
# 输入: 通过 stdin 收到 JSON,字段含 session_id / source(startup|resume|clear|compact) / cwd
# 输出: stdout 一行 JSON,key 必须是 hookSpecificOutput.additionalContext
# 退出码: 0 正常,非 0 该 hook 失败但不阻塞会话
# ============================================================

set -e
cd "${CLAUDE_PROJECT_DIR:-.}"
export PYTHONIOENCODING=utf-8

# 加载共享日志
source "$(dirname "$0")/_log-helper.sh"

# ---------- 收集状态信息 ----------

# 当前周
WEEK=$(date +%Y-W%V)

# 本周报告数(排除 _changes.md 这种汇总文件)
CURR_COUNT=0
if [ -d reports/current ]; then
  CURR_COUNT=$(find reports/current -name "*.md" -not -name "_changes.md" 2>/dev/null | wc -l | tr -d ' ')
fi

# 最近一次归档目录 + 修改时间
LAST_ARCHIVE="(无)"
LAST_TIME="(无)"
if [ -d reports/archive ]; then
  LAST_DIR=$(ls -td reports/archive/*/ 2>/dev/null | head -1)
  if [ -n "$LAST_DIR" ]; then
    LAST_ARCHIVE=$(basename "$LAST_DIR")
    LAST_TIME=$(date -r "$LAST_DIR" "+%Y-%m-%d %H:%M" 2>/dev/null \
              || stat -c "%y" "$LAST_DIR" 2>/dev/null | cut -c1-16)
  fi
fi

# 检查凭证配置(只看是否有非空值,不卡 https 前缀)
DING_OK="未配置"
FEISHU_OK="未配置"
if [ -f .env ]; then
  # 行首是 KEY=,值不是空字符串(即不是 KEY="" 也不是 KEY=)
  grep -qE '^DINGTALK_WEBHOOK="?[^"[:space:]]+' .env 2>/dev/null && DING_OK="已配置"
  grep -qE '^FEISHU_WEBHOOK="?[^"[:space:]]+'   .env 2>/dev/null && FEISHU_OK="已配置"
fi

# ---------- 组装 additionalContext ----------
CONTEXT="📡 supplier-monitor 项目状态自动加载(SessionStart hook)
- 当前周次: ${WEEK}
- 本周 reports/current/ 报告数: ${CURR_COUNT}
- 最近归档: ${LAST_ARCHIVE}(${LAST_TIME})
- 推送凭证: 钉钉 ${DING_OK} / 飞书 ${FEISHU_OK}
"

# 记录日志
hook_log "session-start" "INFO" "会话启动 reports=${CURR_COUNT} archive=${LAST_ARCHIVE} dingtalk=${DING_OK} feishu=${FEISHU_OK}"

# 用 python 输出严格合法的 JSON(避免手拼引号翻车)
python -c "
import json, sys
print(json.dumps({
  'hookSpecificOutput': {
    'hookEventName': 'SessionStart',
    'additionalContext': sys.argv[1]
  }
}, ensure_ascii=False))
" "$CONTEXT"
