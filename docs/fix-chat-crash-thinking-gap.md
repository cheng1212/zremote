# 变更说明：自动滚动崩溃修复 + 思考指示本地兜底

> 分支：`fix/chat-crash-thinking-gap` → `develop`　提交：`f086949`
> 日期：2026-09-06　关联诊断：《zremote-对话刷新与模型切换崩溃诊断.md》#1、#2

## 问题

1. **崩溃（回归 bug，commit ba370fb 引入）**：`_maybeAutoScroll()` 被放在 `Builder.builder` 里同步调用，内部 `_scroll.animateTo(0)` 在 build 期执行——注释声称 post-frame 但代码没做。触发条件"新消息到达 + 用户在底部"= 每次模型回复开始时的瞬间，表现为偶发红屏/崩溃，体感上像模型切换引起。
2. **思考指示死区**：`_thinkingLabel` 要求 phase=running + 无流式 + 尾行 userInput 三条件同时满足；发送确认到服务端落行/翻 phase 之间（服务端预热/排队慢时长达数秒）什么都不显示。

## 修复

1. 删掉 Stack 里的 `Positioned.fill + Builder` 探针块；`_maybeAutoScroll()` 改为在 AnimatedBuilder builder 里经 `addPostFrameCallback` 调度（与 setLivePhase 同模式）。
2. `_thinkingLabel` 增加本地兜底：存在"已送达且尚未被服务端行确认、且未点亮「网络较慢」"的回显时，也显示等待提示；`slow` 标志（20s）点亮后兜底自动隐藏，防无限转圈掩盖真实故障。

## 验证

- `flutter analyze` 0 问题，66 测试全过
- 崩溃路径：会话有历史行时打开/收到新消息不再有 build 期 animateTo
- 死区路径：发送后服务端慢响应期间界面持续显示"$model 正在思考"
