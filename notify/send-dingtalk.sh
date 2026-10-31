#!/bin/bash
# ============================================================
# 钉钉群机器人推送脚本(加签模式)
# 用法: bash send-dingtalk.sh <urgent|normal> <markdown_file>
#   urgent  → 紧急消息(@所有人)
#   normal  → 普通消息(不 @)
#
# 环境变量(必需):
#   DINGTALK_WEBHOOK   钉钉机器人 webhook URL
#   DINGTALK_SECRET    钉钉机器人加签 secret
#
# 推荐放在项目根目录的 .env 文件里:
#   DINGTALK_WEBHOOK="https://oapi.dingtalk.com/robot/send?access_token=xxx"
#   DINGTALK_SECRET="SECxxxxxxxxxxxxxxx"
# 然后在调用前: source .env
# ============================================================

set -e
export PYTHONIOENCODING=utf-8

# ---------- 参数检查 ----------
LEVEL="${1:-normal}"
FILE="${2:-}"

if [ -z "$FILE" ]; then
  echo "用法: bash send-dingtalk.sh <urgent|normal> <markdown_file>"
  exit 1
fi

if [ ! -f "$FILE" ]; then
  echo "错误: 文件不存在: $FILE"
  exit 1
fi

# 自动加载 .env(只在变量尚未 export 时加载,不覆盖命令行)
if [ -f ".env" ] && [ -z "${DINGTALK_WEBHOOK:-}" ] && [ -z "${DINGTALK_SECRET:-}" ]; then
  set -a
  source .env
  set +a
fi

if [ -z "${DINGTALK_WEBHOOK:-}" ] || [ -z "${DINGTALK_SECRET:-}" ]; then
  echo "错误: 缺少环境变量 DINGTALK_WEBHOOK 或 DINGTALK_SECRET"
  echo "请设置后重试,或把它们写到项目根目录的 .env 文件"
  exit 1
fi

# ---------- 计算钉钉加签 ----------
# 钉钉签名规则:
#   stringToSign = ${timestamp}\n${secret}
#   sign = base64(HmacSHA256(stringToSign, secret))
#   sign = urlencode(sign)
TIMESTAMP=$(($(date +%s%N) / 1000000))
SIGN_STR=$(printf '%s\n%s' "$TIMESTAMP" "$DINGTALK_SECRET")
SIGN=$(printf '%s' "$SIGN_STR" \
  | openssl dgst -sha256 -hmac "$DINGTALK_SECRET" -binary \
  | base64)
SIGN_ENC=$(python -c "import urllib.parse,sys;print(urllib.parse.quote_plus(sys.argv[1]))" "$SIGN")

# ---------- 准备消息内容 ----------
TITLE="供应商风险周报"
AT_ALL=false

if [ "$LEVEL" = "urgent" ]; then
  TITLE="🔴 紧急:供应商风险升级"
  AT_ALL=true
fi

# ---------- 组装 JSON ----------
# 用 python 直接读文件并组装 JSON,避免 bash 中转破坏 UTF-8 编码
AT_ALL_PY=$([ "$AT_ALL" = true ] && echo "True" || echo "False")
PAYLOAD=$(python -c '
import json, sys
title = sys.argv[1]
at_all = sys.argv[2] == "True"
filepath = sys.argv[3]
with open(filepath, encoding="utf-8") as f:
    content = f.read()
max_len = 18000
if len(content) > max_len:
    content = content[:max_len] + "\n\n> ⚠️ 内容已截断,完整版见 reports/ 目录"
payload = {
    "msgtype": "markdown",
    "markdown": {
        "title": title,
        "text": content
    },
    "at": {
        "isAtAll": at_all
    }
}
print(json.dumps(payload, ensure_ascii=True))
' "$TITLE" "$AT_ALL_PY" "$FILE")

# ---------- 发送 ----------
URL="${DINGTALK_WEBHOOK}&timestamp=${TIMESTAMP}&sign=${SIGN_ENC}"

RESPONSE=$(curl -s -X POST "$URL" \
  -H 'Content-Type: application/json; charset=utf-8' \
  -d "$PAYLOAD")

# ---------- 检查结果 ----------
ERRCODE=$(echo "$RESPONSE" | python -c "import sys,json;print(json.load(sys.stdin).get('errcode', -1))" 2>/dev/null || echo "-1")

if [ "$ERRCODE" = "0" ]; then
  echo "✅ 钉钉推送成功 [$LEVEL]"
  exit 0
else
  echo "❌ 钉钉推送失败 [errcode=$ERRCODE]"
  echo "原始响应: $RESPONSE"
  exit 2
fi
