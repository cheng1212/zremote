# 变更说明：任务列表页参考图改造（四步）

> 分支：`feat/tasks-page-overhaul` → `develop`（6d951ee / 4b43b3a / 1ab146c / 2f80d9b）
> 日期：2026-09-06　UI 延续「柑橘晨光 Citrus Morning」主题（frontend-design 技能）
> 参考图：用户提供的外部 App 会话页截图；按实际可用接口裁剪实现

## 裁剪决策（参考图元素 vs 实际接口）

| 参考图元素 | 决策 | 依据 |
|---|---|---|
| 搜索栏常驻 | ✅ 实现 | 纯本地过滤 |
| 筛选 tab 全部/置顶/最近/归档 | ✅ 实现 | pinned 有；归档三接口探针往返实测通过 |
| 排序「最近更新 ▼」 | ✅ 实现（+创建时间/标题） | taskActivityTs 既有口径 |
| 卡片 chips：状态/模型/时间 | ✅ 实现 | phase 有；模型为任务对象自带字段（探针实测）；时间 taskTimeLabel 既有 |
| 「本地/云端」 | ❌ 裁掉 | 本 App 全为本地桌面会话，无此语义 |
| 「项目 ▼」「添加标签」「移动到项目」 | ❌ 裁掉 | 协议无标签/项目接口 |
| 「复制会话」「导出」 | ❌ 裁掉 | 协议无对应方法 |
| 底部导航 会话/项目/我的 | ✅ 改两 tab | 项目无接口；「我的」承接原弹层里的连接管理 |

## 四步提交

### step1 `6d951ee` 纯逻辑
`lib/state/task_filters.dart`：TaskFilter / TaskSortKey / visibleTaskCards（筛选+查询+排序一站式）；查询匹配标题+预览，recent=7 天活跃窗口；archived 集合独立参与。6 个新单测。

### step2 `4b43b3a` 列表页重构
- AppBar 去搜索切换；搜索栏常驻（清空按钮）；筛选 tab 行 + 排序菜单
- 卡片信息行重排：标题行只留置顶 pin；状态/模型/token/时间成 chips 行（参考图同位置）
- 模型 chip：优先服务端 `t['model']`（取 `/` 后段），缺失退本地意图记录

### step3 `1ab146c` 归档接入
- 探针实测：`listArchivedTasks` / `archiveTask` / `unarchiveTask`（往返归档→恢复验证通过，无残留）
- ZApp：`archivedTasks` + load/archive/unarchive 三方法（本地即时移动，断线清理）
- 页面：归档 tab 切换触发加载；长按菜单加 归档/取消归档
- 探针工具 `manual_archive_probe_test.dart` 入库

### step4 `2f80d9b` 底部导航 + 我的页
- `HomeShell`：IndexedStack(TasksPage, ProfilePage) + 自绘底导（墨线顶边/选中蜜橘/inkFaint 未选中）
- `ProfilePage`：连接卡（relay 状态徽章/设备名/链接摘要/重连/断开）、运行日志卡（最近 8 条挂 logsRevision）、关于卡

## 验证

- `flutter analyze` 0 问题；`flutter test` 82 全过（+6 新增）
- 归档接口经真实桌面端探针往返验证；测试会话无残留

## 审核提示

- `visibleTaskCards` 管理模式同样作用于筛选集（对可见集合批量操作），与旧「管理模式显示全量」行为不同——是有意变更。
- 归档卡长按菜单含「删除」；删除归档会话走的仍是 deleteTask（服务端语义由桌面端保证）。
- 「项目」「标签」「导出」等被裁项：协议层面无对应方法，若后续桌面端补充接口可再排期。
