# zremote 接口排期计划

> 依据 docs/API.md 全量接口清单与现有代码的差集排期（2026-09-04）。
> 节奏：每批 = 实现 → flutter analyze + test → git 提交 →（用户下令）构建部署。
> 图标快捷栏已满 6 枚，新入口优先塞进既有弹层（长按菜单 / 用量面板 / 任务列表），不再加图标。

## 批次一 · 协议层已写好、只差接 UI（一次构建全带上）

| # | 接口 | 入口设计 | 协议层现状 |
|---|---|---|---|
| 1 | `conversationRowsRangeV4` 历史翻页 | 消息列表滑到顶自动加载更早 60 条（`beforeRowId` 追加） | `conversation.dart:446` 已有 `rowsRange()` |
| 2 | `compact` 压缩上下文 | 用量弹层里加「压缩上下文」按钮（>70% 时高亮） | `conversation.dart:253` 已有 `compact()` |
| 3 | `retryTurn` 重新生成 | assistant 行长按菜单「重新生成本轮」；顺手把 `_EchoBubble` 死重试按钮（`() {}`）接上发送重试 | `conversation.dart:435` 已有 `retryTurn()`（CAS+行级 target） |
| 4 | `conversationPlansV4` 计划查询 | 打开会话时拉一次权威计划，兜底粘性缓存（换设备/重进不再丢计划） | `conversation.dart:457` 已有 `plans()` |
| 5 | 技能 + 斜杠命令 | 输入框 `$` 弹技能列表、`/` 弹命令列表（`prepareWorkspace` 已返回 `slashCommands[]`，`skills()` 已写好） | `conversation.dart:471` 已有 `skills()` |

## 批次二 · 会话管理（任务列表增强）

- `archiveTask` / `unarchiveTask` / `listArchivedTasks` —— 归档：列表管理页加归档操作 + 「已归档」入口
- `getTaskTokenUsage` —— 任务列表卡片显示每会话 token 消耗
- `setTaskUnread` —— 标未读（低优先级）

## 批次三 · 对话控制（逐个小改动）

- `pauseGoal` / `resumeGoal` —— 暂停/继续运行中的任务（比停止温和）
- `setFollowupMode` —— 追问排队 vs 引导模式开关
- `setAssistantFeedback` —— 回复点赞/点踩（行长按菜单）
- `editUserQuery` —— 编辑已发消息重发（CAS+行级）
- `forkAssistant` —— 从某条回复分叉新会话（CAS+行级）

## 批次四 · 大件（单独排期）

- automations 定时任务页：`listAllAutomations` / `createAutomation` / `setAutomationEnabled` / `deleteAutomation` / `runAutomationNow` / `restartAutomation`（zemote AutomationsPage 可参考）
- `conversationFileChangesV4` —— 本会话文件变更清单
- `model-provider` getAll/save/delete —— 远程管理模型供应商

## 未探索通道（暂不做）

`file` `git` `terminal` `memory` `bots` `repo-wiki` `off-peak-task` 等 ~30 个通道方法未逆向，有需要再抓包分析。

## 关于 Superpowers

当前会话可用技能列表里没有 Superpowers（头脑风暴/前端美观/TDD 流程类），排期这件事它也帮不上——用「任务清单 + 本文档 + 每批验证提交」的节奏替代，效果等同。若后续装了 Superpowers，批次四的大件（automations 页）可以走它的前端流程。
