#!/bin/bash
# ============================================================
# Hook: PostToolUse(matcher: Write|Edit|MultiEdit)
# 作用: supplier-scout 子智能体每次写一份报告后,
#       自动校验报告是否包含「风险评级」「信息来源」两个必填字段。
#       如缺失,把警告作为 additionalContext 塞回 Claude,
#       让它在下一步自动补救(而不是等到推送时业务方发现报告不完整)
#
# 触发事件: PostToolUse,只对 Write/Edit/MultiEdit 工具
# 输入: stdin JSON,字段 tool_input.file_path 是被写入的文件路径
# 退出码:
#   0  → 校验通过,什么都不做
#   2  → 校验失败,blocking 行为(把 stderr 反馈给 Claude,但 Write 已完成不可撤销)
#         本 hook 选择更柔和的方式:exit 0 + additionalContext,而不是 exit 2
#         理由: 报告字段缺失不是「危险」,只是「质量不达标」,让 Claude 自己感知后修就好
# ============================================================

set -e
cd "${CLAUDE_PROJECT_DIR:-.}"
export PYTHONIOENCODING=utf-8

# 加载共享日志
source "$(dirname "$0")/_log-helper.sh"

# ---------- 解析 stdin ----------
INPUT=$(cat)
FILE_PATH=$(echo "$INPUT" | python -c "
import json, sys
try:
    data = json.load(sys.stdin)
    print(data.get('tool_input', {}).get('file_path', ''))
except Exception:
    print('')
")

# 只关心 reports/current/ 下的供应商报告
# (排除 _changes.md 这种汇总文件,它有自己的格式)
case "$FILE_PATH" in
  *reports/current/_changes.md|*reports/archive/*)
    exit 0
    ;;
  *reports/current/*.md)
    : # 继续校验
    ;;
  *)
    # 不是报告文件,放过
    exit 0
    ;;
esac

# 文件刚被 Claude 写过,理论上一定存在;但保险起见还是检查一下
if [ ! -f "$FILE_PATH" ]; then
  exit 0
fi

# ---------- 校验规则 ----------
PROBLEMS=()

# 规则 1:必须有「风险评级」字段
grep -qE '风险评级' "$FILE_PATH" || PROBLEMS+=("缺少「风险评级」字段")

# 规则 2:必须出现 🟢/🟡/🔴 至少一个
grep -qE '🟢|🟡|🔴' "$FILE_PATH" || PROBLEMS+=("未出现风险等级 emoji(🟢/🟡/🔴)")

# 规则 3:必须有「信息来源」段落(也接受「来源」二字)
grep -qE '信息来源|来源' "$FILE_PATH" || PROBLEMS+=("缺少「信息来源」段落")

# 规则 4:报告长度需要在合理区间(supplier-scout 规约要求 800-1500 字中文)
# 注意:wc -m 在不同 locale 下行为不一致,这里用 python 数 unicode 字符更稳
WORDCOUNT=$(python -c "import sys; print(len(open(sys.argv[1], encoding='utf-8').read()))" "$FILE_PATH" 2>/dev/null || echo 0)
if [ "$WORDCOUNT" -lt 600 ]; then
  PROBLEMS+=("报告过短(${WORDCOUNT} 字符,期望 ≥ 800 字)")
fi

# ---------- 反馈 ----------
if [ ${#PROBLEMS[@]} -eq 0 ]; then
  # 校验通过,静默退出(不要刷屏)
  hook_log "post-write-lint" "PASS" "$(basename "$FILE_PATH") 校验通过 (${WORDCOUNT}字符)"
  exit 0
fi

# 记录校验问题
hook_log "post-write-lint" "WARN" "$(basename "$FILE_PATH") ${PROBLEMS[*]}"

# 把问题作为 additionalContext 反馈,让 Claude 知道并可主动修
PROBLEM_TEXT=$(printf '  - %s\n' "${PROBLEMS[@]}")
WARN="⚠️ post-write-lint 发现 ${FILE_PATH} 存在格式问题:
${PROBLEM_TEXT}
建议在继续后续步骤前补充上述字段,或在主会话提示用户人工核查。"

python -c "
import json, sys
print(json.dumps({
  'hookSpecificOutput': {
    'hookEventName': 'PostToolUse',
    'additionalContext': sys.argv[1]
  }
}, ensure_ascii=False))
" "$WARN"

exit 0
