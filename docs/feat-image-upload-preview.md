# 变更说明：图片上传与预览增强（对话框缩略图 + 聊天内联回显）

> 分支：`feat/image-upload-preview` → `develop`
> 日期：2026-09-08　参考：OpenCode 移动 Web 端编排（用户截图）

## 用户诉求

图片在**发送前的输入栏**和**发送后的聊天记录**里都要能预览，参照 OpenCode
的排版（多图网格、消息内直接看图）。

## 现状与缺口（改造前）

- 输入栏 `_AttachmentBar` 已有缩略图，但只有一个 `+` 入口走**系统文件管理器**，
  一次只能选一个文件；选相册图体验差
- 相册选出的图常见**没有扩展名**（Android content uri）→ 上传 mime 落到
  `application/octet-stream`，输入栏判不出是图（不画缩略图），聊天回显也可能
  退化成文件 chip
- 聊天里多图逐条纵排堆叠，不是参考图的网格

## 改动

### 1. 相册选图入口（chat_page）

- 输入栏新增 **图片按钮**（`Icons.photo_outlined`）：`FileType.image +
  allowMultiple + withData`，直接走系统相册、一次多选
- 上限：单次发送最多 9 个图片/文件；单个 >100MB 跳过并提示
- 原「+」按钮保留，走文件管理器选任意文件

### 2. 无扩展名图片兜底（composer_logic + chat_page）

- 新增纯函数 `sniffImageMime(bytes)`：按魔数识别
  PNG(`89 50 4E 47`) / JPEG(`FF D8 FF`) / GIF(`GIF8`) / WEBP(`RIFF`+偏移8=`WEBP`)，
  认不出返回 null
- 上传时 `_mimeFor(ext)` 落到 octet-stream → 用嗅探结果兜底，
  保证服务端把图当图（回显/桌面端都受益）
- 新增 `attachmentIsImage(map)`：mime 前缀优先、扩展名兜底的统一渲染口径，
  AttachmentView 与网格分区的判定共用一份（原先两处各写一份会漂移）

### 3. 聊天内联回显网格（rows.dart）

- `UserBubble` 附件编排抽成 `attachmentChildren()`：**多图双列网格**
  （LayoutBuilder 按气泡宽自适应格子 110~210），单图/非图文件维持原纵排
- `AttachmentView` 加 `boxSize`：网格模式下固定方格（cover 裁切 + 按显示尺寸
  解码省内存），加载/失败态渲染成等大格子，列表不错位
- 回显兜底：字节到手后 `sniffImageMime` 补判，无 mime/无后缀的图也能显示
  （原来会一直挂文件 chip）

### 4. 回显零等待（chat_page）

- 上传成功后 `globalImageCache.put(ref, bytes)` 直接进缓存：本地回显立即出图，
  不再走 attachmentRead 拉一遍（省一次往返，弱网体验明显）

## 验证

- `flutter analyze` 0 问题
- `flutter test` 112 过 / 13 skip（新增 5：嗅探 3 + 渲染口径 2）
- `dart format` 全量

## 审核提示

- 上传协议未动：仍是 attachmentBegin/Chunk/Commit（384KiB 分片），本次只改
  mime 兜底与展示层
- `sniffImageMime` 是纯字节判定，不信任文件名/扩展名——安全面无新增
- 多图网格 cell 用 `cover` 裁切：非方图会裁边，全图看请点开（InteractiveViewer
  保留）
