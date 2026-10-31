#!/bin/bash
# ============================================================
# 飞书群机器人推送脚本(自定义机器人 + 签名校验)
# 用法: bash send-feishu.sh <urgent|normal> <markdown_file>
#   urgent  → 紧急消息(红色卡片头)
#   normal  → 普通消息(蓝色卡片头)
#
# 路线说明:
#   本脚本走的是「飞书群自定义机器人」webhook 路线,不是飞书 MCP。
#   优点:零依赖、curl 直发、5 分钟可上线
#   适用:课堂教学、轻量自动化
#   不适用:需要主动 @ 个人、跨群路由、读对话历史等富场景(那要用 MCP)
#
# 环境变量(必需):
#   FEISHU_WEBHOOK   飞书机器人 webhook URL
#   FEISHU_SECRET    飞书机器人签名校验 secret
#
# 推荐放在项目根目录的 .env 文件:
#   FEISHU_WEBHOOK="https://open.feishu.cn/open-apis/bot/v2/hook/xxxx-..."
#   FEISHU_SECRET="xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx"
#
# ⚠️ 三个常踩的坑:
#   1. 飞书 timestamp 是「秒」,钉钉是「毫秒」,千万别混
#   2. 飞书 HMAC 用的 key 是 secret 自己,被签的串是 "${ts}\n${secret}"(注意换行)
#   3. 群机器人安全设置一定要选「签名校验」,不要选「自定义关键词」(关键词会拦中文 markdown)
# ============================================================

set -e
export PYTHONIOENCODING=utf-8

# ---------- 参数检查 ----------
LEVEL="${1:-normal}"
FILE="${2:-}"

if [ -z "$FILE" ]; then
  echo "用法: bash send-feishu.sh <urgent|normal> <markdown_file>"
  exit 1
fi

if [ ! -f "$FILE" ]; then
  echo "错误: 文件不存在: $FILE"
  exit 1
fi

# ---------- 自动加载 .env(只在变量尚未 export 时加载,不覆盖命令行) ----------
if [ -f ".env" ] && [ -z "${FEISHU_WEBHOOK:-}" ] && [ -z "${FEISHU_SECRET:-}" ]; then
  set -a
  source .env
  set +a
fi

# 飞书是「可选」推送通道。如果没配凭证,优雅跳过(打印一行 INFO 并 exit 0,
# 这样在 weekly-monitor 流水线里它不会让钉钉一起失败)
if [ -z "${FEISHU_WEBHOOK:-}" ] || [ -z "${FEISHU_SECRET:-}" ]; then
  echo "ℹ️  跳过飞书推送(未配置 FEISHU_WEBHOOK / FEISHU_SECRET)"
  exit 0
fi

# ---------- 计算飞书签名 ----------
# 飞书签名规则(官方文档):
#   stringToSign = ${timestamp}\n${secret}
#   sign = base64(HmacSHA256(stringToSign, key=secret))
# 注意:飞书 timestamp 是「秒」级,跟钉钉的「毫秒」级不一样
TIMESTAMP=$(date +%s)
SIGN=$(python -c "
import hmac, hashlib, base64, sys
ts, secret = sys.argv[1], sys.argv[2]
string_to_sign = f'{ts}\n{secret}'
sign = base64.b64encode(hmac.new(string_to_sign.encode('utf-8'), digestmod=hashlib.sha256).digest()).decode('utf-8')
print(sign)
" "$TIMESTAMP" "$FEISHU_SECRET")

# ---------- 准备消息标题与卡片色 ----------
TITLE="📊 供应商风险周报"
TEMPLATE="blue"

if [ "$LEVEL" = "urgent" ]; then
  TITLE="🔴 紧急:供应商风险升级"
  TEMPLATE="red"
fi

# ---------- 组装 JSON 并发送(全程 Python,避免 bash 编码问题) ----------
RESPONSE=$(python -c '
import json, sys, urllib.request
ts, sign, title, template, filepath, webhook = sys.argv[1:7]
with open(filepath, encoding="utf-8") as f:
    content = f.read()
max_len = 28000
if len(content) > max_len:
    content = content[:max_len] + "\n\n> ⚠️ 内容已截断,完整版见 reports/ 目录"
payload = json.dumps({
    "timestamp": ts,
    "sign": sign,
    "msg_type": "interactive",
    "card": {
        "config": {"wide_screen_mode": True},
        "header": {
            "title": {"tag": "plain_text", "content": title},
            "template": template
        },
        "elements": [
            {"tag": "markdown", "content": content}
        ]
    }
}, ensure_ascii=False).encode("utf-8")
req = urllib.request.Request(webhook, data=payload,
    headers={"Content-Type": "application/json; charset=utf-8"})
resp = urllib.request.urlopen(req)
sys.stdout.buffer.write(resp.read())
' "$TIMESTAMP" "$SIGN" "$TITLE" "$TEMPLATE" "$FILE" "$FEISHU_WEBHOOK")

# ---------- 检查结果 ----------
# 飞书成功返回 {"code":0,"msg":"success",...} 或 {"StatusCode":0,...}
if echo "$RESPONSE" | grep -qE '"code":0|"StatusCode":0'; then
  echo "✅ 飞书推送成功 [$LEVEL]"
  exit 0
else
  echo "❌ 飞书推送失败"
  echo "原始响应: $RESPONSE"
  echo ""
  echo "常见错误码对照:"
  echo "  19021: 签名校验失败 → 检查 FEISHU_SECRET 是否正确"
  echo "  19024: 关键词不匹配 → 群机器人安全设置改成「签名校验」"
  echo "  11000: webhook URL 错 → 检查 FEISHU_WEBHOOK"
  echo "  9499:  请求体过大 → 内容超过 30000 字符,需裁剪"
  exit 2
fi
