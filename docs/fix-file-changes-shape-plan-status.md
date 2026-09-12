# 变更说明：文件变更对齐桌面端新协议 + 计划状态识别 + 错误人话化

> 提交：`290a6fb`（develop）　日期：2026-09-06
> 附探针：`test/manual_plan_probe_test.dart`（抓计划/文件变更真实数据形状）

## 用户反馈

「计划按钮和查看本会话文件变更，打开是 JSON」

## 根因（探针实测定位）

1. **文件变更 = 服务端校验错误原文糊进 UI**。桌面端 3.10.1 对 `conversationFileChangesV4` 的请求做了 zod strict 校验，必须携带：
   ```json
   {"sessionId", "target": {"rowId", "entityId"}, "baseRevision", "baseLogEpoch"}
   ```
   手机端按旧形状只发 `{scope, sessionId}` → 服务端拒绝并返回 zod 错误数组 → 手机端把错误字符串整段显示，弹层里就是一段 JSON。
2. **计划面板状态识别缺口**：快照 plan 形状为 `{items:[{id, content, status}]}`（解析正常），但进行中状态是**驼峰 `inProgress`**，手机端只认 `in_progress`/`active` → 进行中的步骤被画成未开始（视觉上"计划不对劲"加重了整体观感）。
3. `conversationPlansV4` 查询对这几个会话返回空，计划实际来源是快照 `snapshot.plan`——工作正常。

## 修复

| 文件 | 变更 |
|---|---|
| `lib/protocol/conversation.dart` | `fileChanges()` 按 3.10.1 形状发请求：target = 最后一个 turnHeader 行的 `{rowId, entityId}`（探针确认 turnHeader 自带 entityId=turnId），`baseRevision/baseLogEpoch` 取当前快照；无目标行直接返回空。响应解析取 `items`（`{path, additions, deletions, writeCount, toolNames, patches}`）。 |
| `lib/ui/composer_logic.dart` | 新增 `briefRpcError()`：zod 错误数组提取 message 拼接为人话；其余错误截 140 字符。UI 不再显示整段 JSON。 |
| `lib/ui/rows.dart` | `PlanStep.inProgress` 词形归一（大小写不敏感，认 `inProgress`/`in_progress`/`active`/`running`）。 |
| `lib/ui/chat_page.dart` | 文件变更弹层错误文案走 `briefRpcError`；标题与空态改为「最近回合」口径（新协议按回合统计）。 |

## 验证

- 探针实测三会话：正确形状请求全部成功（响应 `{files:0, additions:0, deletions:0, items:[]}`，这些会话本身无文件编辑）；
- `flutter analyze` 0 问题；`flutter test` 77 全过（+2 briefRpcError 单测）。

## 口径变化

- 新协议按**回合**统计文件变更，弹层现在查询**最近一个回合**的数据（标题改为「文件变更（最近回合）」）。若需"全会话累计"，后续可逐回合查询合并（每回合一次 RPC），按需再排。
