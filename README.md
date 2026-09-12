# zremote

ZCode 远程会话的 Android 客户端（Flutter）。手机上连上桌面端 ZCode：
看任务、聊天、传图、管计划、批权限——协议是逆向出来的，文档在
[docs/API.md](docs/API.md)。

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

## 构建与部署

- `build-apk.ps1` / `build-flutter-apk.ps1`：两个打包脚本（细节略有差异，
  产物都在 `build/app/outputs/flutter-apk/`）。
- 日常验证：`flutter analyze` + `flutter test`（纯逻辑层全量单测）。
- 改动协议层前先看 API.md 对应小节；形状未实测的服务端返回一律做多形态
  兜底解析（参考 `parseTaskTokenUsage` / `describeFileChange` 的写法）。

## 安全提示

- **配对链接就是凭据**：`sid + hash` 拿到即可冒充该终端会话。目前明文存
  `SharedPreferences`，仅自用可接受；对外分发前必须迁移
  `flutter_secure_storage`，并处理 applicationId / 正式签名 / 混淆。

## 已知限制

- 附件上传整文件读进内存，>100MB 在选择时拦截。
- 图片附件缓存只在进程内（64MB LRU），冷启动后首屏重新拉取。
- 桌面端只支持"链接配对"一种入口；未实现扫码。
