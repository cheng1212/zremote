# zremote 接口差集矩阵（客户端 vs 桌面端能力）

> 依据：docs/协议接口参考.md（实测文档）+ 桌面端 zcode.cjs 考古 + 客户端全量
> 调用清单盘点（2026-09-12）。客户端已调用方法实测枚举自 lib/ 全部 RPC 调用点。
> 状态：✅已接入 ｜🟡协议有·未接（可补）｜🔴不可达（桌面端未暴露给移动端通道）｜⬛未探索通道

## 一、zcode-agent（V4 会话核心）——主干全接

命令：createSession ✅ sendText ✅ stop ✅ compact ✅ pauseGoal/resumeGoal ✅
switchModelConfig ✅ switchCollaborationMode ✅ setFollowupMode ✅ setApprovalMode ✅
resolveInteraction ✅ retryTurn ✅ forkAssistant ✅ sendQueuedNow ✅ deleteQueueItem ✅
setAutoDrain ✅ deleteSession ✅ cancelBackgroundWork ✅

🟡 **editUserQuery**（编辑已发消息重发，CAS+行级）——微信式长按改消息，用户价值高
🟡 **applyFileRewind**（文件回滚，CAS+行级）——撤销 agent 的文件改动，高价值
   （前提：conversationFileChangesV4 已接入，回滚预览用 fileRewindPreviewV4）

订阅：subscribe/unsubscribe/resyncConversationV4 ✅ subscribeSessionsIndexV4 ✅
查询：conversationRowsRangeV4 ✅ conversationPlansV4 ✅ conversationFileChangesV4 ✅
🟡 conversationFileRewindPreviewV4（配合 applyFileRewind）

## 二、zcode-task（任务管理）

listTasks/listPinnedTasks/listArchivedTasks ✅ archiveTask/unarchiveTask ✅ deleteTask ✅
renameTask ✅ setTaskPinned ✅ prepareWorkspace ✅ getTaskTokenUsage ✅
🔴 setTaskUnread——双证否决（2026-09-12）：桌面端 3.11.2 源码无此方法
   （zcode.cjs 无 zod 定义，调用即 Method not found）；且客户端 UI 无未读显示面
🟡 getTaskSnapshotWithEtag——增量刷新，低优先

## 三、automation（zcode-agent 通道）

listAllAutomations/createAutomation?/setAutomationEnabled ✅ deleteAutomation ✅
runAutomationNow ✅ listAutomationRuns ✅ restartAutomation 🟡未接（文档列了）

## 四、usage-stats / skills / commands

getAppUsageSnapshot ✅ skills.list ✅ commands.list ✅

## 五、🔴 不可达（桌面端 ZCode Protocol 内部服务，未挂移动端通道，探针已验证）

workspace/readState、workspace/setDefaultModel、setDefaultThoughtLevel、setDefaultMode、
workspace/upsertModelProvider、removeModelProvider、generateText、session/setModel
（persistAsWorkspaceLastUsed 形态）、session/updateRuntimeModelConfig
→ 结论：「服务端工作区默认模型」这条跨设备默认的正解，移动端**当前协议不可达**，
除非桌面端在未来版本把这些方法挂上 Channel IPC 路由。保持关注桌面端更新。

## 六、⬛ 未探索通道（约 30 个，文档见协议参考 §其余通道）

已明可用性：usage-stats ✅（getAppUsageSnapshot 已接）；off-peak-task（错峰任务，
桌面端高频自用）🟡可探索；subagents 🟡（会话页已有快照字段，通道级操作未接）；
hooks/memory/bots/terminal/git/file/credential/oauth/plugin*/settings-sync 等 ⬛
无移动端场景或需逐一抓包，建议按需探索，不批量硬接。

## 七、补齐建议排序（按用户价值）

1. **editUserQuery**——聊天高频操作，CAS/行级基础设施全在（retryTurn 同款），成本中
2. **applyFileRewind + fileRewindPreview**——agent 文件改动可撤销，安全网级功能
3. restartAutomation——自动化页补全，成本极低
4. editQueueItem——排队消息改字，成本中
5. setTaskUnread / getTaskSnapshotWithEtag——低优
