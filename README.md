# Supplier Monitor · 供应商风险监控自动化系统

> Claude Code 四件能力组合实战:Subagent 并行 + Skill 编排 + `/loop` 周一自动巡检 + Hooks 防呆 + 钉钉飞书 webhook 双推

---

## 🚀 5 分钟快速启动

### 第 1 步:确认环境

```bash
# Claude Code 必须 v2.1.72 或更高
claude --version
```

如果没装,参考:
- macOS: `brew install --cask claude-code`
- Windows: `winget install Anthropic.ClaudeCode`
- Linux: 参考 https://docs.claude.com/en/docs/claude-code

### 第 2 步:配置推送机器人(2-4 分钟)

#### 钉钉(必配)

1. 钉钉群 → **群设置** → **智能群助手** → **添加机器人** → **自定义机器人**
2. 安全设置选 **"加签"**
3. 拿到两样东西:
   - Webhook URL(`https://oapi.dingtalk.com/robot/send?access_token=...`)
   - Secret(以 `SEC` 开头的一串字符)
4. 编辑当前目录下的 `.env` 文件,填入这两个值

#### 飞书(可选,留空则只发钉钉)

1. 飞书群 → **群设置** → **群机器人** → **添加机器人** → **自定义机器人**
2. 安全设置选 **「签名校验」**(不要选「自定义关键词」,中文 markdown 容易被关键词过滤吃掉)
3. 拿到两样东西:
   - Webhook URL(`https://open.feishu.cn/open-apis/bot/v2/hook/...`)
   - Secret(机器人详情页签名校验下显示的一串字符,长度 32 位左右)
4. 把这两个值填进 `.env` 的 `FEISHU_WEBHOOK` / `FEISHU_SECRET`

> 本项目飞书走的是「群自定义机器人 webhook + 加签」路线,**不**依赖飞书 MCP。
> webhook 路线零依赖、5 分钟上线;MCP 路线适用于需要主动 @ 个人、读群消息等富场景,本项目暂不需要。

```bash
# 编辑 .env(已经预置占位符,把 REPLACE_WITH... 换成你的真实值)
nano .env
```

### 第 3 步:启动 Claude Code 验证

```bash
claude
```

进入 Claude Code 会话后:

```
> /agents          # 应该看到 supplier-scout
> /init            # 让 Claude 把项目"读一遍"
```

### 第 4 步:跑第一次

```
> 运行 weekly-monitor Skill,完成一次完整供应商监控流水线
```

等 8–10 分钟,你会:
- 看到屏幕上 **「N agents running」**(并行震撼时刻!)
- `reports/current/` 里出现 12 份独立报告
- 钉钉群里收到一条总结消息

### 第 5 步:注册周一自动巡检

```
> /loop 0 8 * * 1
请运行 weekly-monitor Skill,完成一次完整的供应商监控流水线。
```

返回:`Cadence: Every Monday at 08:00` —— 你已经雇了一个不睡觉的实习生 🎉

---

## 📁 项目结构

```
supplier-monitor/
├── README.md                              ← 你正在读的文件
├── CLAUDE.md                              ← 项目宪法,Claude 每次会话自动加载
├── HOOKS-EXERCISE.md                      ← Hooks 练习讲解(★ 新增)
├── suppliers-demo.csv                     ← 12 家演示供应商(公开数据)
├── .env                                   ← 钉钉/飞书凭证(已 .gitignore 保护)
├── .env.example                           ← 凭证模板(可提交 git)
├── .gitignore                             ← 防泄露
│
├── .claude/
│   ├── settings.json                      ← 项目级 hooks 配置(★ 新增,提交 git)
│   ├── settings.local.json                ← 本地权限/覆盖(不提交)
│   ├── hooks/                             ← Hooks 脚本目录(★ 新增)
│   │   ├── session-start.sh               ← 进会话提示上次跑的状态
│   │   ├── post-write-lint.sh             ← 报告写完做格式校验
│   │   ├── pre-notify-guard.sh            ← 推送前 _changes.md 体检
│   │   └── stop-log.sh                    ← 流水线结束追加运行日志
│   ├── agents/
│   │   ├── supplier-scout.md              ← 单家供应商调研子智能体
│   │   └── change-detector.md             ← 变化识别子智能体
│   └── skills/
│       └── weekly-monitor/
│           └── SKILL.md                   ← 总编排流水线
│
├── reports/
│   ├── current/                           ← 本周报告(每次跑会写这里)
│   └── archive/                           ← 历史归档(自动按周分文件夹)
│
├── scripts/
│   └── archive-rotate.sh                  ← 智能归档(同周重跑不归档,跨周自动按实际周次归档)
│
└── notify/
    ├── send-dingtalk.sh                   ← 钉钉推送(webhook + 加签)
    └── send-feishu.sh                     ← 飞书推送(webhook + 签名校验,非 MCP)
```

---

## 🎯 核心心法

| 能力 | 角色 | 解决什么 |
|------|------|---------|
| Subagent 并行 | **工人** | 12 家同时调研,8 分钟跑完,不污染主上下文 |
| Skill 编排 | **工头** | 把多步流水线打包成一条命令 |
| `/loop` 定时 | **闹钟** | 周一 8 点自动开始 |
| Webhook 推送 | **邮差** | 把结论从终端搬到团队群(钉钉 + 飞书并列双发) |
| **Hooks 防呆** | **保安** | 在工具调用前后做确定性校验,不靠模型自觉(★ 新增) |

> 五件合起来,你拥有的不是工具,是**自主运行的小系统**。

> Hooks 与前四件不同:它是**确定性**的(每次都跑、不靠模型记得),
> 适合放校验、防呆、日志这类「绝对不能漏」的关卡。详见 `HOOKS-EXERCISE.md`。

---

## ⚠️ 重要提示

### 关于演示数据

`suppliers-demo.csv` 里是 **12 家公开上市公司**(博世、法雷奥、宁德时代等),所有调研基于公开新闻,**不涉及任何真实采购数据**。

**生产替换为内部数据时,请遵守你公司的数据合规流程**,使用公司部署的 Claude(Bedrock / Vertex / Foundry 等)。

### 关于 `/loop` 的边界

- `/loop` 是**会话级**的——关掉终端就停
- **7 天自动过期**,过期后需要重新注册
- 真生产部署请切换到:
  - **Claude Code Desktop 定时任务**(Mac/Windows,电脑开着即可)
  - **Cloud 定时任务**(`claude.ai/code/scheduled`,云端跑,你电脑可关)
  - **系统 cron + `claude -p`**(更严合规要求)

> **代码一行不用改,只是触发机制变了**。

### 关于 .env

- `.env` 已被 `.gitignore` 保护,**不会被 git 提交**
- 如果你不小心把真实凭证放在 `.env` 然后又 `git add -f`,**立即去钉钉重置 secret**
- 团队协作时,通过 `.env.example` 共享配置结构,真实值各自配置

---

## 🔍 故障排查

### 「跑了之后,Subagent 串行不并行」

**原因**:触发指令没有明确说"并行"。
**修法**:触发时强调:**"对每一家,**同时并行**派出 supplier-scout"**

### 「我同一天跑了两次,reports/archive/ 没有新增目录?」

**这是正确行为,不是 bug**。

`scripts/archive-rotate.sh` 用「current/ 里报告的实际周次」判断是否归档:
- 同周重跑 → 不归档,直接覆盖刷新本周报告(避免历史里出现一堆只差几小时的快照)
- 跨周重跑 → 归档到 `archive/<那一周>/`;若已存在,自动加 `__rerun-时间戳` 后缀防覆盖

如果你想**强制保留**这次的中间快照:跑之前手动 `cp -r reports/current reports/archive/manual-snapshot-$(date +%H%M)`。

### 「钉钉群没收到消息」

**逐项检查**:

```bash
# 1. .env 里的值是不是真实值,不是占位符?
cat .env | grep DINGTALK

# 2. webhook 单独测试能不能通?
bash notify/send-dingtalk.sh normal CLAUDE.md

# 3. 钉钉机器人安全设置选的是"加签"吗?(不是"自定义关键词")
```

### 「飞书群没收到消息」

```bash
# 1. 检查凭证是否填了(留空是正常跳过,不算错误)
cat .env | grep FEISHU

# 2. 单独测试
bash notify/send-feishu.sh normal CLAUDE.md

# 3. 错误码对照
#   19021 → FEISHU_SECRET 错(签名校验失败)
#   19024 → 安全设置选成了"自定义关键词",改回"签名校验"
#   11000 → FEISHU_WEBHOOK URL 错
```

### 「supplier-scout 报告里有"未披露"」

这是**正常的**。CLAUDE.md 里要求"信息必须有公开来源,无来源就写未披露,不得编造"——这是把 Claude 训练成**负责任的分析师**,不是问题。

### 「报告内容跟现实差距很大」

公开新闻有滞后性。生产部署时建议:
1. 接入更专业的数据源(Bloomberg、路透、企查查 API)
2. 用 MCP 接你公司的 ERP / 采购系统拿真实关联数据
3. 报告生成后,设置一道**人工审阅**步骤(中等风险通过即可,高风险必须审)

---

## 📚 相关资源

- Claude Code 官方文档:https://docs.claude.com/en/docs/claude-code
- Claude Code Hooks 文档:https://docs.claude.com/en/docs/claude-code/hooks
- 飞书自定义机器人文档:https://open.feishu.cn/document/client-docs/bot-v3/add-custom-bot
- 钉钉自定义机器人文档:https://open.dingtalk.com/document/orgapp/custom-robot-access

---

## 📝 课后三档作业

### 🟢 入门
- [ ] 把 `suppliers-demo.csv` 换成你公司真实的 5 家供应商,跑一遍
- [ ] 看群里的消息,标注"哪条有用、哪条没用"

### 🟡 进阶
- [ ] 加一个 `cost-impact-analyzer` 子智能体
- [ ] 在 🔴 报警里自动估算潜在损失金额

### 🔴 高阶
- [ ] 迁到 **Cloud 定时任务**,关电脑也跑
- [ ] 跨周持续运行 1 个月,做一份效果总结

---

*项目模板版本 v1.0 · 适配 Claude Code v2.1.x · 2026 年 5 月*
*教学演示用,生产部署请按公司合规流程执行*
