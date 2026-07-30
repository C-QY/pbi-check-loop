# pbi-check-loop

给 **AI agent** 用的 Power BI Desktop 控制工具。补上 AI 辅助开发 PBI 时断掉的反馈闭环。

**[English →](README_EN.md)** · 仅 Windows · PowerShell 5.1+

> 使用者是 agent，不是人。所以它封装成 Claude Code 的 **skill**，而不是给人敲的命令行别名。

## 解决什么问题

大模型能自主开发软件，靠的是**能自己验证**——跑测试、读输出、再改。
PBI 开发在两个地方结构性地掐断了这条链：

**断点一：模型层的真相有两份。**
TMDL 在磁盘上，Power BI Desktop 在内存里另有一份。Agent 改了磁盘，Desktop 毫不知情；
而且此时按 Ctrl+S 会**用旧内存覆盖掉新磁盘**。所以每次迭代都必须有人手动关掉重开。

**断点二：报表层的产物是像素，不是文件。**
Agent 能写 `visual.json`，但看不见它渲染成什么样——对不对、有没有错位，一概不知。

结果是**人变成了 agent 的眼睛和手**。这不是习惯问题，是结构问题。

## 做了什么

| 工具 | 补的断点 |
|---|---|
| `pbi-reload.ps1` | 一：把「关闭 → 重开 → 关登录弹窗 → 摆回窗口」自动化 |
| `pbi-shot.ps1` | 二：把屏幕像素变成 agent 能读的 PNG |

以前每轮迭代人要做 6 件事：察觉 agent 改完 → 关 Desktop（并正确判断保存与否）→ 等加载
→ 关登录弹窗 → 窗口跳屏了拖回来 → 看结果并**用语言描述给 agent**。

现在人只做第 1 件（在对话里答一句「无未保存改动」），2–5 由工具做，第 6 件 agent 自己做。

## 做不到什么

- **没有加快加载**。Desktop 加载大模型的时间一秒没省，那才是耗时大头
- **agent 不能操作报表**：不能滚动、点击、切页。问题不在当前这屏就得人先导航过去
- **没有把人从决策里拿掉**，而且是故意的：磁盘改动与内存未存改动方向相反，
  工具从外部分不出来，只有人知道
- 只解决「看」，不解决「改」报表层

## 安装

需要 Windows + PowerShell 5.1+，装了 Power BI Desktop。

```powershell
git clone <repo-url>
cd pbi-check-loop
.\install.ps1
```

装两样东西：

- `bin\*.ps1` → `~\.claude\tools\`
- `skill\SKILL.md` → `~\.claude\skills\pbi-check-loop\`

装完自检语法和 UTF-8 BOM。重启 Claude Code 后 skill 生效，agent 会在合适时机自动用它。

卸载：`.\install.ps1 -Uninstall`

## 用法

```powershell
& "$env:USERPROFILE\.claude\tools\pbi-reload.ps1" -ListOnly       # 只看状态
& "$env:USERPROFILE\.claude\tools\pbi-reload.ps1" -Yes            # 重载
& "$env:USERPROFILE\.claude\tools\pbi-shot.ps1"  -Out shot.png    # 截窗口
```

### ⚠️ `-Yes` 是什么意思

它表示**已经跟人确认过「Desktop 里没有未保存的改动」**。不给这个参数，脚本只打印警告不动手。

因为有两种方向相反的情况，工具从外部分不出来：

| 情况 | 正确做法 |
|---|---|
| 磁盘 TMDL 被改过、Desktop 内存是旧的 | 绝不能保存（会覆盖磁盘改动） |
| 人刚在 Desktop 里改了还没存 | 必须先保存（否则杀掉就没了） |

Desktop 标题栏不带修改标记，枚举窗口也拿不到脏状态——**只有人知道**。所以确认这一步不能省，
也不该由脚本弹框去问（那是打扰），应该发生在对话里。

## 可推广的部分

> 任何 GUI 开发工具，只要它 ①把状态存在自己内存里而非磁盘、②产出是视觉而非文本，
> 就会以同样的方式掐断 agent 的反馈闭环。
> 补法是固定的两招：**把状态刷新机械化**，**给 agent 开一条截屏通道**。

这跟 PBI 无关，换成 Figma、Unity、CAD、任何 IDE 插件都成立。

## 一句更诚实的

这两个脚本加起来 400 多行 PowerShell，**本身没有技术含量**。真正花时间的是那些实证——
登录弹窗延迟 11 秒才出现、守候进程必须独立否则随会话死、`IsZoomed` 返回 True 时窗口可能
根本没撑开……**任何人重做一遍都会踩同样的坑**。

价值在 [`skill/SKILL.md`](skill/SKILL.md) 末尾那 10 条踩坑记录，不在代码。
