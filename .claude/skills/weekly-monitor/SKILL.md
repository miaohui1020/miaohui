---
name: weekly-monitor
description: 完整执行一次供应商监控流水线:并行调研所有供应商 → 对比上周变化 → 推送报警到飞书/钉钉群。当用户说"周一巡检""跑一次监控""weekly-monitor""执行供应商巡检"时触发。
allowed-tools: [Bash, Read, Write, Task]
---

# 周度供应商监控流水线

你的任务:**完整执行一次供应商监控流水线**,从读取主数据到推送报警。

## 执行步骤(必须严格按顺序)

### Step 1:准备工作目录(智能归档)

```bash
bash scripts/archive-rotate.sh
```

这个脚本会自动判断:
- **current/ 为空 / 不存在** → 跳过(首次运行)
- **current/ 内容属于今天所在周**(同周重跑)→ **不归档**,主流程随后会覆盖刷新本周报告
- **current/ 内容属于过去某一周**(跨周新跑)→ 归档到 `reports/archive/<那一周>/`
  - 若该目录已存在且非空 → 自动改用 `archive/<那一周>__rerun-YYYY-MM-DD_HHMM/`,不丢历史

> 周次锚点用「current/ 里最新报告的修改时间」推断,不依赖「今天的上一个周一」——
> 这意味着你可以**周一定时跑、周三临时复跑、周日补跑**都不会错档。
> 实现细节见 `scripts/archive-rotate.sh`。

### Step 2:读取供应商主数据

```bash
cat suppliers-demo.csv
```

解析为结构化清单。每一行是一家供应商,字段包括:
`name_zh, name_en, name_slug, category, country, annual_spend_cny, owner`

### Step 3:并行派出 supplier-scout 子智能体(关键步骤!)

对 csv 中的每一行,派出一个独立的 `supplier-scout` 子智能体。

**⚠️ 极重要:必须明确说"同时并行地"派出,不要串行执行**

调用方式:
> "对 suppliers-demo.csv 中的所有供应商,**同时并行地**派出 supplier-scout 子智能体进行尽调。
>  每个子智能体负责一家。等所有子智能体完成后,把它们的回执汇总成总览表。"

每个子智能体会:
- 接收 name_zh / name_en / name_slug / category 参数
- 自己完成 4 维度调研
- 写报告到 `reports/current/<name_slug>.md`
- 返回 80 字摘要

### Step 4:派出 change-detector 子智能体识别变化

派出 `change-detector` 子智能体一次,让它做对比工作:

> "调用 change-detector 子智能体,对比 `reports/current/` 与 `reports/archive/` 中最近一次归档,
>  生成 `reports/current/_changes.md`。**只返回一行总结,不要返回 _changes.md 全文给主会话**。"

change-detector 会:
- 自动找最近一次归档目录(若没有归档,会写入"首次基线"标识)
- 逐家对比,识别 4 类变化:🔺 升级 / ➕ 新增 / 🔻 降级 / ➖ 解除 / ⚪ 无变化
- 写出严格格式的 `_changes.md`,**末尾会写「推荐推送等级:urgent / normal / skip」**
- 只把一行汇总返回主会话,不污染上下文

**关键:不要让主会话自己读两份目录做对比** —— 那样上下文会被 12 份报告塞满,Step 6 的"主会话只 3 行"就破功了。change-detector 的存在就是为了**保护主上下文**。

### Step 5:推送报警(钉钉 + 飞书,并列双推)

读取 `reports/current/_changes.md` 末尾的 **「推荐推送等级:urgent / normal / skip」** 字段,
按 change-detector 给的判断推。**钉钉和飞书并列发,任何一个失败不影响另一个**。

- **urgent**(有 🔺 升级)→ 紧急推送
  ```bash
  bash notify/send-dingtalk.sh urgent reports/current/_changes.md
  bash notify/send-feishu.sh   urgent reports/current/_changes.md
  ```
- **normal**(仅 ➕ 新增 / 🔻 降级 / ➖ 解除)→ 普通推送
  ```bash
  bash notify/send-dingtalk.sh normal reports/current/_changes.md
  bash notify/send-feishu.sh   normal reports/current/_changes.md
  ```
- **skip**(全部 ⚪ 无变化 / 首次基线)→ 不推送,仅在主会话简短确认

注意:
- 飞书脚本走的是「群自定义机器人 + 签名校验」webhook 路线(不是飞书 MCP)
- 如果 `.env` 里没配 `FEISHU_WEBHOOK` / `FEISHU_SECRET`,飞书脚本会优雅跳过(返回 0),便于课堂只配钉钉就能演示
- 把推送结果记下来(`钉钉 ✓/✗`、`飞书 ✓/✗`),Step 6 要用

### Step 6:主会话只输出 3 行总结

最后,主会话**只输出 3 行**:

```
✅ 本周巡检完成 · <时间>
📊 风险变化:<X> 升级 / <Y> 新增 / <Z> 解除 / <N> 维持
📨 推送状态:钉钉 ✓ / 飞书 ✓
```

不要在主会话输出每家的细节。**主会话保持干净**。

## 关键约束

1. **Step 3 必须并行**,这是这条流水线的灵魂——少了并行,Subagent 设计意义全失
2. **Step 6 主会话只 3 行**,不要把子智能体的回执罗列出来——保持上下文干净
3. **所有写入文件的路径都必须正确**,不要写到根目录
4. **推送失败不影响主流程**,但要在主会话最后一行如实标注 `推送状态:钉钉 ✗ / 飞书 ✓`(双推任一失败不阻塞另一个)
5. 如果 csv 中某家解析失败,跳过并在 `_changes.md` 里加一条"⚠️ <slug> 解析失败,需人工核查"

## 执行示例

用户说:"运行 weekly-monitor"

你的内心独白(不要输出):
1. 读 csv → 12 家
2. 并行派 12 个 supplier-scout
3. 等 8 分钟,收 12 份回执
4. 派 1 个 change-detector 做对比,得到「推荐推送等级」
5. 按 change-detector 的建议调推送脚本(钉钉+飞书并列)
6. 输出 3 行总结

最终主会话输出:
```
✅ 本周巡检完成 · 2026-05-11 08:09
📊 风险变化:1 升级 / 2 新增 / 0 解除 / 9 维持
📨 推送状态:钉钉 ✓ / 飞书 ✓
```

**这就是这条流水线该有的样子——简单、干净、自动**。
