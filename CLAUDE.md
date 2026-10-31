# 供应商风险自动化监控系统

## 这是什么
对关键 Tier-1 供应商做每周自动风险扫描,发现风险变化主动推送到飞书/钉钉群。
本项目用于教学演示,生产化部署请切换到 Cloud 定时任务。

## 关键流程
每周一 08:00 由 `/loop` 自动触发 `weekly-monitor` Skill,执行以下步骤:
1. 读取 `suppliers-demo.csv`,对每家供应商**并行派出** `supplier-scout` 子智能体
2. 报告写入 `reports/current/<supplier-slug>.md`(`PostToolUse` hook 自动 lint 报告字段)
3. 派 `change-detector` 子智能体对比 `reports/archive/上一周/` 与 `reports/current/`,写 `_changes.md`
4. 仅当存在变化(评级升降、新增重大事件)时,推送到钉钉群和飞书群(`PreToolUse` hook 推送前防呆)
5. 把 `reports/current/` 的内容归档到 `reports/archive/<年-周>/`
6. 主会话只输出 3 行总结(`Stop` hook 追加一行运行日志)

> Skill / Subagent 是「概率性」(模型决定),Hooks 是「确定性」(事件触发)。
> 关键校验、防呆、日志这类「绝对不能漏」的事情,放在 hook 里;详见 `HOOKS-EXERCISE.md`。

## 报告统一模板(supplier-scout 必须遵守)
1. 公司基本盘(注册地、规模、近 3 年营收趋势)
2. 财务风险信号(评级变动、债务、回款异常)
3. 合规与法律风险(诉讼、处罚、制裁名单)
4. 运营风险(停产、安全事故、关键人员变动)
5. 与我司业务关联度(供货品类、年采购额、可替代性)
6. 风险评级:🟢 低 / 🟡 中 / 🔴 高
7. 信息来源清单(每条事实必须有公开来源链接)

## 数据来源优先级
1. 上市公司公告 / 年报
2. 监管机构(SEC、证监会、市场监管总局)
3. 头部财经媒体(路透、彭博、财新、21 经济报道、Wall Street Journal)
4. 工商信息(企查查、天眼查的公开摘要)
5. 行业媒体作为补充

## 推送规则
- 只推变化,不推全量(避免群消息疲劳)
- 🔴 高风险 → 顶部置顶 + @相关负责人(从 csv 的 owner 字段读取)
- 🟡 中风险 → 普通消息
- 🟢 → 🟢(无变化)→ 不推送
- 推送渠道:**钉钉群 + 飞书群并列双推**(都走 webhook + 签名校验,不走飞书 MCP);任一失败不影响另一个

## 重要规则(不可违反)
- 信息必须有公开来源,无来源即写"未披露",**不得编造**
- 不要在主会话里详细罗列每家细节,主会话只看子智能体总结
- 推送内容里不得出现内部敏感信息(年采购额、合同价等)
- 教学演示阶段使用脱敏数据 `suppliers-demo.csv`,生产替换为内部数据时
  请遵守公司数据合规流程

## 项目结构
```
supplier-monitor/
├── CLAUDE.md                              # 本文件(项目宪法,每次会话自动加载)
├── HOOKS-EXERCISE.md                      # Hooks 教学讲解
├── README.md                              # 5 分钟上手指南
├── suppliers-demo.csv                     # 演示数据(脱敏)
├── .env / .env.example                    # 钉钉/飞书凭证
├── .claude/
│   ├── settings.json                      # 项目级 hooks(提交 git,团队共用)
│   ├── settings.local.json                # 本地权限白名单(不提交)
│   ├── hooks/                             # 4 个生命周期 hook 脚本
│   │   ├── session-start.sh               #   SessionStart: 项目状态注入
│   │   ├── post-write-lint.sh             #   PostToolUse: 报告字段校验
│   │   ├── pre-notify-guard.sh            #   PreToolUse: 推送前防呆
│   │   └── stop-log.sh                    #   Stop: 运行日志追加
│   ├── agents/
│   │   ├── supplier-scout.md              # 单家供应商调研(并行 ×N)
│   │   └── change-detector.md             # 对比变化,生成 _changes.md
│   └── skills/
│       └── weekly-monitor/SKILL.md        # 总编排流水线
├── reports/
│   ├── current/                           # 本周报告
│   └── archive/                           # 历史归档(按周分文件夹)
├── scripts/
│   └── archive-rotate.sh                  # 智能归档(同周重跑不归档)
└── notify/
    ├── send-dingtalk.sh                   # 钉钉推送(webhook + 加签)
    └── send-feishu.sh                     # 飞书推送(webhook + 签名校验,非 MCP)
```

## 常用命令
- 触发一次完整流水线:让 Claude 运行 `weekly-monitor` Skill
- 注册周一定时:`/loop 0 8 * * 1` 后跟流水线指令
- 查看已注册的定时任务:在会话中问 "列出当前所有定时任务"
- 查看 Subagent:`/agents`

## 教学边界
本项目用于课堂演示和入门学习。生产部署请注意:
- `/loop` 是会话级的,关终端就停。生产用 Cloud 定时任务或 Desktop 任务
- Subagent 的并发上限受订阅档位影响,大批量请分批
- 内部数据接入应通过公司部署的 Bedrock / Vertex / Foundry 版本

## 为什么飞书走 webhook,不走 MCP
本项目早期版本曾接飞书 MCP(需要飞书应用、tenant_access_token、@imAPI 等一整套),
教学复现成本太高。现在统一收敛到「群自定义机器人 + 签名校验」webhook:
- **优点**:零依赖、curl 直发、5 分钟可上线、与钉钉脚本同构
- **代价**:无法主动 @ 个人(只能 @所有人 / 关键词高亮),无法读对话历史,无法跨群路由
- **判断准则**:课堂演示和绝大多数风险报警场景,webhook 已经够用;如果你需要让机器人
  「读群里的回复」「按业务方查询自动回话」,那才是 MCP 的主场,本项目不在此列
