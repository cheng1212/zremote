# 变更说明：新会话模型放行闸门（确认模型就绪才发首条消息）

> 分支：`feat/draft-model-ready-gate` → `develop`　提交：`309ee1f`
> 日期：2026-09-06　背景：《zremote-桌面端交互深度研究报告.md》§2.1 registryFallback 根因

## 需求

新会话**必须**落在用户自己的模型上（NVIDIA nv-nemotron-ultra，经本地 4002 代理），因为工作区默认模型（千问 qwen3.8-flash）欠费跑不通。且由于模型切换存在延迟/被服务端回退的可能，要求**等待模型实际切换成功后才允许发送首条消息**。

## 实现方式

利用既有链路做闭环验证，几乎零额外延迟：

```
createSession(config: nv-nemotron-ultra)   ← 模型配置随建会话下发，
  ↓                                          桌面端 applyRequestedSessionConfig
openSession → 订阅                           当场应用/校验（provider 不在册直接拒）
  ↓
等待订阅快照回读（10s 上限，200ms 轮询）      ← openSession 本来就要等快照
  ├─ 快照就绪 & 模型 == 请求值 → 放行 sendText
  ├─ 快照就绪 & 模型 != 请求值 → 立即失败：
  │    "会话模型被服务端置为 …，未落到请求的 …（大概率本地模型代理未启动或不可用）。消息未发送"
  └─ 快照迟迟不来 → 超时失败
```

要点：

1. **桌面端 registryFallback 的窗口被关死**：即便建会话后服务端把模型回退（代理下线/注册表刷新），快照回读会发现不一致，首条消息不会发进欠费模型。
2. **草稿路径去掉重复的 `_assertLocalModel`**：config 已随 createSession 应用，快照验证取代"盲发一次对齐命令"——省一轮 CAS 往返。已有会话保留发送前对齐（后写者赢语义不变）。
3. **判定逻辑纯函数化**：`sessionModelMatches()`（composer_logic.dart）——model 必须一致；请求了 provider 时 provider 必须一致（防同名模型跨供应商回退）。附 3 个单测。
4. 用户在草稿里手动选过模型时同样走此闸门（`_draftConfig()` 返回用户选择）。

## 验证

- `flutter analyze` 0 问题；`flutter test` 69 全过（+3 新增）
- 手动场景：正常情况模型已就绪（快照到达即匹配），额外等待 ≈0；代理下线场景气泡给出明确失败原因，可重试

## 已知边界

- 桌面端若"接受请求但模型实际连不通"（代理在建会话后立刻挂掉），快照仍显示请求模型，闸门放行——第一轮会在 provider connect 阶段报错，会话级 ErrorCard 兜底显示（错误可见性此前已修）。
- 超时上限 10s 为常量，如遇慢预热环境可调。
