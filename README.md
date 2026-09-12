# zremote

ZCode 远程会话的 Android 客户端（Flutter）。手机上连上桌面端 ZCode：
看任务、聊天、传图、管计划、批权限——协议是逆向出来的，文档在
[docs/API.md](docs/API.md)。

> 自用项目，配合桌面端 ZCode（Electron）使用。当前状态：功能完整可用，
> 真机验收清单见 [docs/ROADMAP.md](docs/ROADMAP.md) 末节。

## 功能一览

- **会话列表**：多项目管理、置顶（跨项目生效）、归档、批量操作、
  「全部对话」跨项目视图、token 消耗角标
- **聊天**：流式输出（流式区独立面板，滑动稳定）、Markdown/代码块渲染、
  图片/文件上传（可取消）、编辑重发、重新生成、点赞点踩、分叉会话、
  历史翻页、消息拖拽选择复制（中文菜单）
- **队列**：忙会话排队追加、折叠栏、重复消息自动去重（含桌面端定时消息）、
  编辑/重排/立即发送
- **任务事件通知**：完成/报错/中断/等待确认/连接中断，全项目覆盖（20s 轮询）、
  报错带具体原因（如"余额不足 HTTP 402"）、点通知跳会话、铃声/震动可配、
  锁屏可见
- **会话控制**：暂停/继续（保留现场）、停止、压缩上下文（状态化按钮）、
  追问模式、权限审批面板
- **其他**：断线自动重连+状态对账、草稿持久化、通知跳转、深链配对

## 使用说明

### 前置条件

- 桌面端 ZCode（Electron 版）已登录，且开启「远程控制 / Web Remote」；
- 手机与桌面端同一网络环境（经中继服务器中转，详见协议文档）。

### 配对（首次）

1. 桌面端生成远程配对链接（形如
   `https://zcode.z.ai/remote/v4?sid=…&hash=…&t=…`）；
2. 手机 App 首页粘贴链接 → 点「连接桌面端」；
3. 顶部出现「已连接」并加载出项目列表即配对成功。配对信息持久化，
   之后打开 App 自动重连。

> **配对链接就是凭据**（sid+hash 可冒充该终端），不要发给不可信的人。

### 日常使用

- 底部栏：模型 / 模式权限 / 工具 / 计划 / 用量 / 任务（子代理·后台任务·定时任务）；
- 发送输入框左侧 ➕：图片（相册）、文件、技能、斜杠命令；
- 运行中会话：黄色=暂停（保留现场可继续），红色=停止（终止本回合）；
- 断线自动重连并与服务端对账；桌面端崩溃重启后手机数秒内自愈。

## 五层协议栈

```
Relay WebSocket (wss + HMAC proof)
  └─ 信令配对（sid + hash）
      └─ rpc-frame 分片（CRC 校验，超限切块）
          └─ Channel IPC（initialize / promise / event）
              └─ 业务方法（ConversationV4 / workspace / task …）
```

每层的帧格式、方法表、CAS（baseRevision 乐观锁）语义都在
[docs/API.md](docs/API.md)；常量集中在 `lib/protocol/constants.dart`
（防锈设计：协议更新只改这一个文件）。

## 从源码构建

```bash
flutter pub get
flutter analyze          # 0 问题
flutter test             # 全过
flutter build apk --release
# 产物：build/app/outputs/flutter-apk/app-release.apk
```

## 安全提示

- **配对链接就是凭据**：`sid + hash` 拿到即可冒充该终端会话。目前明文存
  `SharedPreferences`，仅自用可接受；对外分发前必须迁移
  `flutter_secure_storage`，并处理 applicationId / 正式签名 / 混淆。
- 仓库内不落任何真实配对链接/密钥（探针一律走 `ZREMOTE_PROBE_LINK`
  环境变量）。

## 已知限制

- 附件上传整文件读进内存，>100MB 在选择时拦截。
- 图片附件缓存只在进程内（64MB LRU），冷启动后首屏重新拉取。
- 桌面端只支持"链接配对"一种入口；未实现扫码。
- 通知依赖 App 进程存活（无推送服务），进程被系统杀死后收不到。
- 更多边界见 [docs/KNOWN-LIMITS.md](docs/KNOWN-LIMITS.md)。
