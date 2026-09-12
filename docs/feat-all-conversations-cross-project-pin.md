# 变更说明：项目切换器「全部对话」+ 跨项目置顶

> 提交：`b749dbc`（全部对话）+ `ee3acb2`（跨项目置顶）　日期：2026-09-11
> 同批：`ea86bb9` 修项目切换报错（BUG-09，见 `docs/BUGFIXES.md`）

## 需求（用户原话）

「第一个功能是项目切换和管理　项目切换有时候会报错，同时项目切换加一个全部对话筛选
　同时会话置顶功能在具体的项目筛选中也有效果」

拆成三条：

1. 项目切换有时报错 → 单独立项 **BUG-09**（已完成，根因是订阅带了 `existing-only`）
2. 项目切换里加「全部对话」筛选 → 用户明确：**与项目并列放在切换弹层最上面**
3. 会话置顶在具体项目筛选里也有效果 → 用户明确选**读法二**：
   **在「全部对话」里置顶过的会话，切到它所属项目单独看时，仍然是置顶状态**

## 改造前的现状

- 列表数据**只含当前项目**：`listTasks` + `listPinnedTasks`（都带当前项目 scope）
  再与 sessions-index 合并。
- 项目切换 = **整条桥栈重建**（销毁 chat / index / conv / bridge → `openBridge` → 重订阅）。
- 置顶是"按项目"的：置顶集合来自 `listPinnedTasks(scope)`。

## 实现

### 1. 数据源：bootstrap 的 `tasks[]`

协议里 `bootstrap-response` 一直带 `result.tasks[]`（**整机级、跨项目**），
但代码只用了 `workspaces[]`——`tasks[]` 从未被接入。这次直接用上，不必给每个项目各开一条桥。

- 新增纯逻辑 `parseBootstrapTasks`（`lib/state/task_sort.dart`）。形状**未实测**，
  按项目约定做多形态兜底：元素可能是任务对象本身，也可能是
  `{task: {...}, workspacePath: ...}` 这类包装（工作区字段在外层）；id 可能是
  `taskId` / `id` / `sessionId`。**认不出 id 的元素直接丢弃**——「全部对话」宁缺勿错。
- 归属解析：`taskProjectKey`（workspacePath > workspaceIdentity > workspaceKey）、
  `taskProjectLabel`（路径尾段）。
- 入库探针 `test/manual_bootstrap_tasks_probe_test.dart`（环境变量门控、无凭据自动 skip）：
  拿到配对链接即可把兜底收成实测结论，同时验证跨项目 `setTaskPinned`。

### 2. 视图切换：只换数据源，**不动桥**

- 新增 `allProjectTasks`（整机任务）与 `viewingAllProjects`，唯一分岔点是
  `listedTasks` getter。
- `showAllProjects()` 只切数据源并重拉 bootstrap，**不碰当前项目的桥**——所以从
  「全部对话」切回项目不用重新开桥，也不会打断正在跑的会话。
- 切到具体项目（`openWorkspace` 成功）会自动退出「全部对话」。
- 列表页数据源、下拉刷新、批量入口都跟着 `listedTasks` / `viewingAllProjects` 走。

### 3. 跨项目打开会话

「全部对话」里点别的项目的卡片，先 `ensureTaskProject(t)` 把桥切到它所属项目再打开——
否则会拿当前项目的桥去开别人的会话。切不过去就**不打开**并明说，不硬闯。

### 4. 跨项目置顶

- **`_taskScope` 修正**：任务自带 `workspacePath` 时以它为准；只有确实是当前项目
  （或压根没写路径）才补当前项目的 `workspaceIdentity`。原实现会拼出
  `path=X + identity=Y` 的错 scope，服务端要么拒、要么打错项目。
- **`setTaskPinned` 改乐观更新**：先记本地记录并重排（置顶要立刻跳到最前，不能等下次
  `loadTasks`），再发 RPC；失败回滚并提示。
- 本地记录 `_pinOverrides` **故意不持久化**：它是乐观层不是权威，重启即清；
  `loadTasks` 时若服务端状态已跟上就撤掉记录——这样他端取消置顶也能正常体现出来。

## 验证

- `flutter analyze` 0 问题；`flutter test` **124 全过**（新增 8 个解析/归属用例，
  `manual_*` 探针 17 个自动 skip）。

## 真机验收点（待用户）

1. 项目切换器**顶部**出现「全部对话」，点进去能看到**所有项目**的会话，卡片带**所属项目标签**。
2. 在「全部对话」里点**别的项目**的会话 → 能正常打开（会自动切桥），不会开错会话。
3. 在「全部对话」里置顶某会话 → 切到它所属项目单独看，它**仍在最前且显示置顶图标**。
4. 切换失败时界面**留在原项目**，不再出现"标题是新项目、列表是旧项目"。

## 未实测 / 边界

- `bootstrap.tasks` 的字段形状未实测（多形态兜底，探针待跑）。
- **跨项目 `setTaskPinned` 是否被服务端接受未实测**：当前桥属于别的项目，靠 scope 里的
  `workspacePath` 指向目标项目。探针里含该实验（跑完立刻还原原状态）。
  若服务端拒绝，本地乐观层仍能保证**本次会话内**显示正确，但重启后会回到服务端状态
  ——届时应改成"先切桥再置顶"。
- 「全部对话」视图**不拉 token 角标**（跨项目 `getTaskTokenUsage` 未实测，
  避免朝不确定的路径乱发 RPC）。
- 「全部对话」的置顶排序来自卡片自带的 `pinned` 字段 + 本地乐观层；
  若 bootstrap 不带 `pinned`，则以本地层为准（同会话内正确）。
