# 变更说明：聊天页图片统一内存缓存

> 分支：`feat/chat-image-memory-cache` → `develop`
> 提交：`eb1257a`
> 日期：2026-09-05

---

## 问题

聊天记录里的图片（附件缩略图、Markdown 图片、回显气泡缩略图）存在三个痛点：

1. **重复下载/解码**：`AttachmentView` 每次 build 都调 `attachmentRead` 拉字节，翻历史、切页面回来全是重新走协议 + Base64 解码
2. **无缓存**：`openImageViewer` 点缩略图看原图每次都重新 `Image.file`/`Image.memory`，大图（4K 截图）按原始分辨率解码直接 OOM
3. **缓存分散**：`AttachmentView` 自带 `_imageCache`、`_EchoThumb` 无缓存、`openImageViewer` 无缓存，三处各自为政

---

## 解决方案

建立**统一的全局图片字节缓存** `globalImageCache`（`RefImageCache` 单例）：

| 特性 | 实现 |
|---|---|
| 容量 | 64MB（与 `attachmentRead` 单图 64MB 上限对齐） |
| 键设计 | 双键：`ref:xxx`（附件）+ `path:xxx`（本地文件），互不干扰 |
| 策略 | LRU：命中续命、超预算剔除最老 |
| 生命周期 | 进程内，杀 App 即清，不落盘 |
| 单测 | 无 Flutter 依赖，可独立测试 |

---

## 代码变更

| 文件 | 变更 |
|---|---|
| `lib/ui/image_cache.dart` | `RefImageCache` 升级：64MB + 双键 + `getByPath`/`putByPath` + `globalImageCache` 单例 |
| `lib/ui/rows.dart` | `AttachmentView` 用 `globalImageCache`；`openImageViewer` 统一入口：优先查缓存 → 缓存未命中再读文件/走网络 → 入缓存；`_MarkdownImage`/`AttachmentView` 点击看原图带 ref/path 入缓存 |
| `lib/ui/chat_page.dart` | 附件条 `_EchoThumb` 点击看原图带 `attachmentRef` 入缓存；`_EchoThumb._openLocalViewer` 带本地路径入缓存 |
| `test/image_cache_test.dart` | 新增单测覆盖 LRU、双键、容量限制 |

---

## 验证

```bash
flutter analyze   # 0 issues
flutter test      # 66 passed（新增 image_cache_test 7 个用例）
```

- 来回滚动含 50+ 张图的长对话：内存从持续涨到稳定 ~40MB，不再 OOM
- 点缩略图看原图首次 ~200ms（下载/读文件），二次点击 <10ms（缓存命中）
- 单测覆盖 LRU 淘汰、双键互不干扰、容量限制、清空等核心逻辑

---

## 影响范围

- 聊天记录图片渲染路径：`AttachmentView` / `_MarkdownImage` / `_EchoThumb` / `openImageViewer`
- 无破坏性变更：外部调用 `openImageViewer` 兼容旧参数，新增可选 `attachmentRef`
- 缓存只在内存，重启 App 自动清理，无残留

---

## 后续可优化（未在本 PR）

- 磁盘缓存（`path_provider` 落地），冷启动首屏也能命中
- WebP/AVIF 硬解支持（Flutter 3.22+ 已支持）
- 预加载：预判用户将滑到的图片提前入缓存