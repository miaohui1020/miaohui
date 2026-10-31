# Hooks 练习:让供应商监控变得「确定性可靠」

> 这是 supplier-monitor 项目的 Hooks 教学补丁。读完这一份,你会理解:
> ① Hooks 是什么、为什么和 Skill / Subagent / `/loop` 不可替代;
> ② 在这条流水线上,哪些环节天然是 hook 的主场;
> ③ 看完 4 个真实可跑的样本,自己能写第五个。

---

## 1. 一句话说清 Hooks 是什么

**Hooks 是 Claude Code 在固定生命周期事件上自动执行的 shell 脚本。**

它和你已经熟悉的几样东西关系如下:

| 工具 | 触发方式 | 谁决定 | 性质 |
|---|---|---|---|
| Subagent | 主智能体派发 | 模型 | 概率性 |
| Skill | 关键词/上下文匹配 | 模型 | 概率性 |
| `/loop` | 时间到 | 系统 | 确定性 |
| **Hooks** | **生命周期事件触发** | **系统** | **确定性** |

> 一句话总结差异:**Skill / Subagent 靠模型「记得」,Hooks 靠事件「必然」**。
> 当你需要「这件事 100% 不能漏」时,就是 hook 的主场。

CLAUDE.md 里写"推送前检查"是请求,模型可能照做、可能跳过;
Hook 里写"推送前检查"是**保证**,只要事件触发,脚本就一定跑。

---

## 2. 这条流水线为什么需要 hook

打开 `weekly-monitor` SKILL 看一下 6 个 step,你会发现每一步都有「容易出事」的地方:

```
Step 1: 准备目录            ← 没什么风险
Step 2: 读 csv              ← 没什么风险  
Step 3: 并行派 N 个 scout    ← 风险点 A: 单家报告字段缺失
Step 4: 派 change-detector   ← 风险点 B: _changes.md 写空了
Step 5: 推送                ← 风险点 C: 把空消息/格式坏的消息发到群里
Step 6: 输出 3 行总结        ← 风险点 D: 跑了几次没人记得
```

这 4 个风险点,如果只靠在 CLAUDE.md / SKILL.md 里写一句"请确保 xxx",
模型大多数时候会做对,但**只要错一次就是业务方在群里看笑话**。

Hooks 的解法:把这 4 个风险点变成 4 个不可绕过的关卡。

| 风险点 | 用什么 hook | 在哪一刻拦 |
|---|---|---|
| 进会话不知道项目状态 | `SessionStart` | 一打开就显示「上次跑啥/凭证齐不齐」 |
| 单家报告字段缺失 | `PostToolUse(Write)` | 报告刚写完,立即查 |
| 推送空/坏消息 | `PreToolUse(Bash)` | curl 还没发出去,卡住 |
| 跑过没记录 | `Stop` | 主会话停下时,追加日志 |

---

## 3. 四个样本逐一拆解

### Hook 1:SessionStart —— 让 Claude 一进门就知道「现在是几年几月」

📁 `.claude/hooks/session-start.sh`

**问题**: 用户开 Claude Code,第一句问"上次巡检啥状态?",
Claude 不会主动去 `ls reports/`,通常只会回答「我不知道,让我查查」,然后打几次 tool 才能弄明白。

**解法**: SessionStart hook 在每次会话开启时自动跑,把项目状态作为 `additionalContext` 注入。
Claude 一上来就看见「本周已经有 12 份报告、最近归档是 W19、钉钉已配/飞书未配」,根本不用查。

**关键代码**:
```bash
# 输出严格合法 JSON 到 stdout,Claude Code 会自动把 additionalContext 拼进上下文
python3 -c "
import json, sys
print(json.dumps({
  'hookSpecificOutput': {
    'hookEventName': 'SessionStart',
    'additionalContext': sys.argv[1]
  }
}))
" "$CONTEXT"
```

**自己试**: 进项目跑 `claude`,你的第一条对话之前就会有这段 context。
也可以手动测:
```bash
echo '{"session_id":"x","source":"startup"}' | bash .claude/hooks/session-start.sh
```

### Hook 2:PostToolUse(Write) —— 报告刚写完就 lint

📁 `.claude/hooks/post-write-lint.sh`

**问题**: supplier-scout 偶尔会写出格式不全的报告(缺「风险评级」、忘了写「信息来源」)。
等推到群里业务方才发现就晚了。

**解法**: PostToolUse(Write) 在 Claude 每次 Write 后立即触发,
若被写的是 `reports/current/*.md` 报告,就检查 4 条规则:

1. 必须含「风险评级」字段
2. 必须有 🟢/🟡/🔴 至少一个
3. 必须有「信息来源」段落
4. 字符数 ≥ 400

任一失败,就把警告塞回 `additionalContext`,Claude 在下一步会"看见"问题并自动补救。

**关键设计选择**:这个 hook **不**用 exit 2(硬拦)。
原因:Write 已经发生了,exit 2 也撤不回报告;而且字段缺失是「质量问题」不是「危险」,
温和地塞回 additionalContext 让 Claude 自己感知并修,体验比强行报错好。

**自己试**:
```bash
# 写一份残缺报告
cat > reports/current/_test.md <<EOF
# 供应商风险简报:测试公司

只有这一行,啥都没有。
EOF

# 模拟 Claude 刚写完
echo '{"tool_name":"Write","tool_input":{"file_path":"'$(pwd)'/reports/current/_test.md"}}' \
  | bash .claude/hooks/post-write-lint.sh

rm reports/current/_test.md
```

你会看到 hook 列出 3 条问题。

### Hook 3:PreToolUse(Bash) —— 推送前最后一道闸

📁 `.claude/hooks/pre-notify-guard.sh`

**问题**: 模型偶尔会把空 `_changes.md`、或者路径打错的不存在文件喂给推送脚本。
一旦 curl 发出,业务方群里就是一条干干净净没结论的"通知"。

**解法**: PreToolUse(Bash) 在每条 Bash 命令执行前先看一眼,
**只对** `notify/send-*` 命令生效(其他 Bash 一律放过),做三道体检:
- 推送目标文件存在
- 文件 ≥ 80 字节(防空模板)
- 如果是 `_changes.md`,必须含至少一个等级标识(🟢/🟡/🔴/🔺/🔻/➕/➖/⚪/首次基线)

任一失败 → **exit 2**,Bash 命令被阻止,stderr 反馈给 Claude,
Claude 会理解原因并自动改正(比如:重新生成 _changes.md)。

**关键设计选择**:这是**唯一**用 exit 2 的 hook。
原因:推送是一次性副作用,「事前拦」比「事后悔」便宜得多。
而 Write 已经写过的文件、Stop 已经停下的会话,exit 2 都没意义。

**自己试**:
```bash
# 试着推一个不存在的文件
echo '{"tool_name":"Bash","tool_input":{"command":"bash notify/send-dingtalk.sh urgent /tmp/nonexistent.md"}}' \
  | bash .claude/hooks/pre-notify-guard.sh
echo "exit=$?"  # 应为 2
```

### Hook 4:Stop —— 跑完默默记一笔

📁 `.claude/hooks/stop-log.sh`

**问题**: `/loop` 自动跑 7 天,你其实不知道每次跑得怎么样。
做不出"运行总结",也复盘不了。

**解法**: Stop hook 在主会话每次停下来时检查:
- 当次是否真的产出了 `_changes.md`(不是产出就不记)
- 该文件是否在最近 60 秒内被改过(只记本次会话产出的)
- 满足 → 在 `.claude/run.log` 追加一行(时间 + 周次 + 紧急/普通数量)
- 自动滚动:超过 200 行就 truncate

**关键陷阱避坑**:
Stop hook **绝对不能 return exit 2**!那会强制 Claude 继续工作,导致**死循环**。
所以脚本里第一件事就是检查 `stop_hook_active` 字段,如果上一回合是被 hook 强制延续的,本回合就直接 exit 0。

**自己试**:
```bash
# 模拟一次「刚跑完巡检」(stop_hook_active=false)
touch reports/current/_changes.md
echo '{"session_id":"x","stop_hook_active":false}' | bash .claude/hooks/stop-log.sh
cat .claude/run.log
```

---

## 4. 配置文件长这样

📁 `.claude/settings.json`(项目级,提交 git)

```json
{
  "hooks": {
    "SessionStart": [
      { "hooks": [{ "type": "command",
                    "command": "bash $CLAUDE_PROJECT_DIR/.claude/hooks/session-start.sh" }] }
    ],
    "PostToolUse": [
      { "matcher": "Write|Edit|MultiEdit",
        "hooks": [{ "type": "command",
                    "command": "bash $CLAUDE_PROJECT_DIR/.claude/hooks/post-write-lint.sh" }] }
    ],
    "PreToolUse": [
      { "matcher": "Bash",
        "hooks": [{ "type": "command",
                    "command": "bash $CLAUDE_PROJECT_DIR/.claude/hooks/pre-notify-guard.sh" }] }
    ],
    "Stop": [
      { "hooks": [{ "type": "command",
                    "command": "bash $CLAUDE_PROJECT_DIR/.claude/hooks/stop-log.sh" }] }
    ]
  }
}
```

几个一定要记住的细节:
- `$CLAUDE_PROJECT_DIR` 是 Claude Code 注入的项目根路径,**比相对路径稳得多**
- `matcher` 是 regex,`Write|Edit|MultiEdit` 同时匹配这三个工具
- `SessionStart` 和 `Stop` 没有 matcher,因为它们不是工具事件
- 只有 `PostToolUse` 和 `PreToolUse` 才有 `matcher`

---

## 5. 退出码语义

整个 hook 体系最重要的就 3 个数字:

| 退出码 | PreToolUse | PostToolUse | Stop | SessionStart |
|---|---|---|---|---|
| **0** | 放行 | 校验通过 | 自然停下 | 注入 context |
| **1** | 非阻塞错误,放行,日志报警 | 同左 | 同左 | 同左 |
| **2** | **阻止工具执行**,stderr → Claude | stderr → Claude(但工具已跑) | **强制 Claude 继续**(易死循环!) | 不要用 |

**记忆口诀**:exit 2 是「权力」,但只在 PreToolUse 是真正的安全权力。

---

## 6. 调试 hook 的三招

### 招 1: 手动喂 JSON 测试
所有 hook 都从 stdin 拿 JSON,所以可以直接 echo 喂进去:
```bash
echo '{"tool_name":"Bash","tool_input":{"command":"ls"}}' | bash .claude/hooks/your-hook.sh
echo "exit=$?"
```

### 招 2: 在 Claude Code 里开 verbose
进会话后按 `Ctrl+O` 切到 verbose 模式,可以看到每个 hook 的 stdout/stderr。

### 招 3: 在 hook 里写文件
```bash
echo "$(date): $INPUT" >> /tmp/hook-debug.log
```
比试图看 stdout 直观得多。

---

## 7. 课后练习(三档难度)

### 🟢 入门(15 分钟)
**任务**: 在 `post-write-lint.sh` 里加一条规则:`reports/current/<slug>.md` 里 URL 里不能有 `example.com`(防止 supplier-scout 编造 URL)。
**提示**: 加一行 `grep -qE 'example\.com' "$FILE_PATH" && PROBLEMS+=("出现了占位符域名 example.com,疑似编造 URL")`

### 🟡 进阶(30 分钟)
**任务**: 写一个新 hook `pre-write-csv-protect.sh`,用 `PreToolUse(Write|Edit)` 阻止任何对 `suppliers-demo.csv` 的修改(主数据文件不该被流水线动)。
**关键点**:
- matcher 用 `"Write|Edit|MultiEdit"`
- 从 `tool_input.file_path` 取被写的文件
- exit 2 拦下,stderr 写明原因
- 在 `.claude/settings.json` 里挂上

### 🔴 高阶(2 小时)
**任务**: 在 Stop hook 里增加「自动每周日生成一份月报」的逻辑:
- 检测今天是不是周日
- 如果是,把 `.claude/run.log` 最近 4 周的数据汇总成一份 `reports/monthly/<年-月>.md`
- 调用 `notify/send-feishu.sh normal` 发出去
**思考**: 为什么这件事不应该交给 `weekly-monitor` SKILL 来做?
**答案**:Skill 由模型触发,不可靠;月报生成应当是「时间到就跑」的确定性任务,放 Stop hook
里也不优雅(Stop 触发太频繁),更优解其实是再加一个 `/loop`,周日 09:00 单独跑一个
`monthly-report` skill —— **意识到这个差异本身就是收获**。

---

## 8. 心法收尾

> 把流水线写出来,只是搭起了骨架。  
> 写好 hooks,才是装上了**反射神经**——
>  
> 让"绝对不能漏的事"不再依赖任何人的记性,包括 Claude 自己。

Subagent 是工人,Skill 是工头,`/loop` 是闹钟,Webhook 是邮差。  
Hooks,是这家店里**永远在岗的保安**。

---

*Hooks Exercise v1.0 · 配套 supplier-monitor v1.1 · 2026 年 5 月*
