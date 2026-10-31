#!/bin/bash
# ============================================================
# Step 1 归档脚本(供 weekly-monitor SKILL 调用)
# ============================================================
# 行为规则:
#   1. current/ 不存在 / 为空(或仅 .gitkeep)     → 啥都不做
#   2. current/ 内容属于「今天所在周」(同周重跑) → 不归档,主流程随后会覆盖刷新
#   3. current/ 内容属于「过去某一周」(跨周新跑) → 归档到 archive/<那一周>/
#      若 archive/<那一周>/ 已存在 且 非空        → 改用 archive/<那一周>__rerun-YYYY-MM-DD_HHMM/
#
# 周次锚点:用 current/ 里**最新一份报告的修改时间**反推它属于哪一周。
#           原因:不能用「今天的上一个周一」—— 周日 23:30 跑跟周一 00:30 跑完全不是同一意图,
#           但 last-monday 算法会把它们当成一回事。看实际报告的 mtime 才是单一可信源。
#
# 用法:bash scripts/archive-rotate.sh
# 退出码:0 正常 / 1 异常
# 输出:一行人类可读 status
# ============================================================

set -e
cd "${CLAUDE_PROJECT_DIR:-.}"

CURRENT_DIR="reports/current"
ARCHIVE_DIR="reports/archive"

# ---------- 检查 current/ 状态 ----------
if [ ! -d "$CURRENT_DIR" ]; then
  mkdir -p "$CURRENT_DIR"
  echo "current/ 不存在,已创建,跳过归档"
  exit 0
fi

# 找到 current/ 里所有 .md 文件(.gitkeep / 隐藏文件不算)
# 用 find 而不是 glob,避免 set -e + nullglob 的坑
MD_LIST=$(find "$CURRENT_DIR" -maxdepth 1 -type f -name "*.md" 2>/dev/null)

if [ -z "$MD_LIST" ]; then
  echo "current/ 为空,跳过归档"
  exit 0
fi

MD_COUNT=$(echo "$MD_LIST" | wc -l | tr -d ' ')

# ---------- 推断 current/ 里报告属于「哪一周」 ----------
# 跨平台拿 mtime: GNU stat / BSD stat 都试一下
get_mtime_seconds() {
  local f="$1"
  stat -c %Y "$f" 2>/dev/null || stat -f %m "$f" 2>/dev/null || echo 0
}
get_week_from_seconds() {
  local sec="$1"
  date -d "@$sec" +%Y-W%V 2>/dev/null \
    || date -r "$sec" +%Y-W%V 2>/dev/null \
    || echo "UNKNOWN"
}

# 找 mtime 最大的那份(=最近修改的报告)
LATEST_FILE=""
LATEST_MTIME=0
while IFS= read -r f; do
  [ -z "$f" ] && continue
  m=$(get_mtime_seconds "$f")
  if [ "$m" -gt "$LATEST_MTIME" ]; then
    LATEST_MTIME=$m
    LATEST_FILE=$f
  fi
done <<< "$MD_LIST"

if [ "$LATEST_MTIME" -eq 0 ]; then
  # mtime 完全拿不到,异常情况,保守归档到 UNKNOWN-日期
  REPORT_WEEK="UNKNOWN-$(date +%Y-%m-%d)"
else
  REPORT_WEEK=$(get_week_from_seconds "$LATEST_MTIME")
  if [ -z "$REPORT_WEEK" ] || [ "$REPORT_WEEK" = "UNKNOWN" ]; then
    REPORT_WEEK="UNKNOWN-$(date +%Y-%m-%d)"
  fi
fi

TODAY_WEEK=$(date +%Y-W%V)

# ---------- 决策 ----------
if [ "$REPORT_WEEK" = "$TODAY_WEEK" ]; then
  # 同周重跑:不归档,主流程会覆盖刷新
  echo "同周重跑(${TODAY_WEEK}),跳过归档,current/ 将被本次运行覆盖刷新"
  exit 0
fi

# 跨周:归档到 archive/<报告实际周>/
TARGET_DIR="$ARCHIVE_DIR/$REPORT_WEEK"

# 若目标目录已存在且有 .md 文件,用 __rerun-时间戳 后缀防覆盖
if [ -d "$TARGET_DIR" ]; then
  EXISTING=$(find "$TARGET_DIR" -maxdepth 1 -type f -name "*.md" 2>/dev/null | head -1)
  if [ -n "$EXISTING" ]; then
    SUFFIX=$(date +%Y-%m-%d_%H%M)
    TARGET_DIR="${ARCHIVE_DIR}/${REPORT_WEEK}__rerun-${SUFFIX}"
  fi
fi

mkdir -p "$TARGET_DIR"

# 移动所有 .md(用 find 列表逐个 mv,稳过 mv current/*.md)
while IFS= read -r f; do
  [ -z "$f" ] && continue
  mv "$f" "$TARGET_DIR/"
done <<< "$MD_LIST"

# ---------- 报告 ----------
echo "归档完成: ${MD_COUNT} 份报告(实际周次 ${REPORT_WEEK}) → ${TARGET_DIR}/"
exit 0
