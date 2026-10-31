#!/bin/bash
# ============================================================
# Hook 共享日志工具
# 用法: source 此文件,然后调用 hook_log <hook名> <级别> <详情>
#   级别: PASS / WARN / BLOCK / INFO / ERROR
# 日志写入 logs/hooks.log,自动轮转(保留最近 500 行)
# ============================================================

HOOK_LOG_DIR="${CLAUDE_PROJECT_DIR:-.}"
HOOK_LOG_FILE="${HOOK_LOG_DIR}/logs/hooks.log"

hook_log() {
  local hook_name="$1"
  local level="$2"
  local detail="$3"
  local ts
  ts=$(date '+%Y-%m-%d %H:%M:%S')

  mkdir -p "$(dirname "$HOOK_LOG_FILE")"
  printf '%s | %-20s | %-5s | %s\n' "$ts" "$hook_name" "$level" "$detail" >> "$HOOK_LOG_FILE"

  # 保留最近 500 行
  local lines
  lines=$(wc -l < "$HOOK_LOG_FILE" 2>/dev/null || echo 0)
  if [ "$lines" -gt 500 ]; then
    tail -n 500 "$HOOK_LOG_FILE" > "${HOOK_LOG_FILE}.tmp" && mv "${HOOK_LOG_FILE}.tmp" "$HOOK_LOG_FILE"
  fi
}
