# 聊天列表滚动稳定性调研与实战修复报告

> **面向读者**：在 Flutter（或任意像素滚动框架）上做聊天界面的开发者 / AI Agent。
> **来源**：zremote（Flutter Android 聊天客户端）两个真实痛点，经两轮 GitHub 源码级调研后根治，用户验收「解决得非常完美」。
> **一句话结论**：
> ① 视口稳定靠**「以消息身份为锚」**（消息 ID + 视口内位置差），绝不按像素增量补偿；
> ② 流式输出的内容增长必须被**钳在一个恒定的布局预算内**（面板封顶/占位符吸收），任何「随内容生长」的面板都会把挤压转嫁给共享空间的兄弟节点。

---

## 问题一：聊天记录「飘来飘去，一下飘老远」

### 1.1 症状

- 滑动停稳后页面自己飘走，偶发朝历史端弹一大段；
- 手势/惯性滚动与内容更新叠加时，视口来回跳。

### 1.2 根因（两层叠加）

**框架层**（Flutter 通用，无法绕过只能缓解）：

- `ScrollPosition.pixels` 锚在**内容起点**，不是可见内容。`reverse ListView` 的起点在最新消息端，视口外行高全靠 **dead reckoning（航位推测）**估算——`RenderSliverList` 源码原话。估算被修正时通过 `SliverGeometry.scrollOffsetCorrection` 直接改写 pixels，表现就是视口跳一下。
- **Flutter 至今没有 scroll anchoring**：官方 issue [flutter/flutter#99158](https://github.com/flutter/flutter/issues/99158)（对标 CSS Overflow Anchor）挂了多年仍 open/P3；官方版 `jumpToIndex`（PR #178021）已被拒。别等框架。
- 默认 `cacheExtent = 250px` 太小：长列表反向滚动时频繁 GC/重建 → `maxScrollExtent`（估算值）反复修正 → 滚动中抖动。

**应用层**（我们自己的补偿算法有方向性缺陷，这是「飘老远」的直接元凶）：

- 旧算法用**内容总高增量**（`maxScrollExtent + viewportDimension` 的差）当「新端增长」全量补进 pixels；
- 但历史端行变高（旧消息图片解码完成、markdown/代码块二次排版）时，屏幕内容纹丝没动、总高却多了 G → 旧算法把用户**往历史端推整个 G**——方向完全反了；
- 配合「欠账回放」（大增量分步追），观感即「停稳之后页面自己飘走，一下飘老远」；
- 另一支路：惯性滚动期间增量照记，惯性一停欠账一次回放 → 顿挫感。
- **教训：像素坐标系下「按增量补偿」永远分不清增量发生在视口哪一侧，方向性错误比不补更糟。**

### 1.3 业界调研（GitHub 源码取证）

| 项目 | 锚定机制 | 关键实现 |
|---|---|---|
| Telegram Android | 消息对象 + 视口内像素偏移 | `ChatActivity.scrollToMessageId`：可见→`view.getTop()` 精确差值；在 adapter→`RecyclerAnimationScrollHelper`；太远→先加载窗口再锚。翻页三段式：**插入前抓顶部可见消息 → 细粒度 notify → 按消息身份找回新位置重放偏移** |
| Telegram Desktop | `ScrollTopState{item, shift}`（消息位置+像素 shift），被 `ListMemento` 持久化 | `saveScrollState()/restoreScrollState()` 成对包裹**一切**列表突变 |
| Signal Android | vendor 掉 LinearLayoutManager | `supportsPredictiveItemAnimations=false`（禁预测动画）；`onLayoutCompleted` 里锚点请求跨 layout pass 存活重试；拖拽中直接丢弃程序化滚动 |
| Element Android | 只认「插入位置==0」的新消息 | 贴底阈值 = 距最新端 2 条；**新消息白名单**防止把任何头部插入都当新消息跟滚 |
| 浏览器（CSS Overflow Anchor 规范） | anchor node + `scrollTop += y1-y0` | 锚点选可见最深节点；锚点自身尺寸变化时取消补偿；**贴底不锚定**——与全部聊天 App 行为同构 |
| Stream Chat Flutter | fork scrollable_positioned_list + **itemKey 身份锚定保留** | 「跟踪视觉顶部 item 的 key，重建后按 key 找回新 index，同内容钉回同一屏幕位置」；贴底判定用 ItemPositions 不用 `offset==maxExtent`（估算值不可靠）；自动滚动策略状态机 + `isScrolling` 护栏 |

### 1.4 修复方案：自实现 scroll anchoring（锚行位置差）

> 选型说明：评估过迁 scrollable_positioned_list（Stream fork 是工业级答案，直接抄它的
> `lib/scrollable_positioned_list/`），但对已有列表是中高成本迁移（滚动语义/keepAlive/
> index 结构全要重排，已修的滚动 bug 全部重回归）。锚行方案与它同思想、改动局部，选定后者。

**核心数据结构**（锚 = 行身份 + 视口内 y）：

```dart
/// 视口顶部（最旧端）可见历史行的采样。
class AnchorSample {
  final int? rowId;   // 行身份；null = 顶部不是历史行，不可锚
  final double topY;  // 锚行顶边在视口坐标系的 y（向下为正）
  const AnchorSample(this.rowId, this.topY);
}

/// 补偿决策纯函数：两次采样定一次补偿量。
abstract final class ViewportAnchor {
  static double? compensate({required AnchorSample? prev, required AnchorSample next}) {
    if (prev == null || prev.rowId == null || prev.rowId != next.rowId) return null; // 身份变了→重定基线不补
    return prev.topY - next.topY; // 视口内 y 差
  }
}
```

**方向推导**（这是整套方案的灵魂，务必要给实现者讲清）：

- 新端内容长高（新行/流式行）→ 锚行被**往上推**（topY 变小）→ delta 为**正** → pixels 增大往历史端滚，把锚行钉回原位；
- **历史端内容长高（图片解码/markdown 重排）→ 锚行被往下推（topY 变大）→ delta 为负 → pixels 减小往回钉**——旧「总高增量」方案在这种场景返回正值（往历史里推），正是飘移根因；
- 锚行自身长高（顶边不动）→ delta = 0，不补；
- 锚行身份变了（翻页/快照重同步/滑出视口）→ null：重定基线，一分不补。翻页与重同步的防误补由此**天然涵盖**，无需再维护翻页纪元、最旧行 ID 等散装标记。

**采样实现**（post-frame，从 RenderObject 拿视觉顶行）：

```dart
AnchorSample? _sampleTopRow() {
  if (!mounted || !_scroll.hasClients) return null;
  final pos = _scroll.position;
  if (!pos.hasContentDimensions || !pos.hasPixels) return null;
  final ctx = pos.context.notificationContext;
  final viewport = RenderAbstractViewport.of(ctx?.findRenderObject());
  if (viewport is! RenderBox) return null;
  RenderSliverMultiBoxAdaptor? sliver;
  viewport.visitChildren((c) { if (sliver == null && c is RenderSliverMultiBoxAdaptor) sliver = c; });
  if (sliver == null) return null;
  RenderBox? topChild; var topY = double.infinity;
  sliver!.visitChildren((child) {
    final y = (child as RenderBox).localToGlobal(Offset.zero, ancestor: viewport).dy;
    if (y < topY) { topY = y; topChild = child as RenderBox; }
  });
  // 用 SliverMultiBoxAdaptorParentData.index 减去头部槽数换算 rowId
  //（换算逻辑必须与 itemBuilder 的 index 语义完全同源）；
  // 顶部若不是历史行（thinking 指示/回显气泡/错误卡）→ 返回 null 不锚。
  ...
}
```

**关键护栏——基线滚动实时跟随**（没有它整套方案会反向放大问题）：

```dart
// _onScroll 里调用：手指/惯性/程序化动画引起的锚行 y 变化，全部实时吞进基线。
// 只有「静止期间的内容变化」才能变成补偿——否则停稳后的第一帧会把整个
// 滚动距离当成「内容增量」回放一遍，视口被拽回滚动前。
void _trackAnchorBaseline() {
  final next = _sampleTopRow();
  if (next != null) _anchorSample = next;
}
```

- 好处：惯性期间欠账**恒为 0**（旧方案「停稳后结算欠账」会把用户滚动距离当增量回放）；
- 对「视口本身尺寸变化」（键盘弹收、面板增减）也自动正确——锚行视觉位置变了就钉回，总高增量方案恰恰在这类场景失明。

**辅助治理**：`scrollCacheExtent` 250 → 1200（约 2.5 屏），翻页往复命中已布局区，dead-reckoning 估算修正大幅减少。不建议社区流传的 5000 级（重 widget 列表内存代价大）。

**保留的观感层**（建议照抄，都是踩坑换来的）：
补偿量过帧末合并桶（同帧多触发源只跳一次）；`minStep 1.5px / 单步上限 600px / 60~110ms linear 短动画`（jumpTo 直接改 pixels 会一闪一闪，动画把修正糊成连续移动）；同一时刻只允许一个补偿动画（两个 animateTo 抢同一 ScrollPosition 就是抖动）；拖拽/惯性中绝不补偿。

### 1.5 效果

- 停在历史区等图片/卡片加载完：视口钉死（旧方案会往历史端弹）；
- 流式输出中上滑看历史：钉死；
- 翻页往复、惯性甩动停稳：无飘移、无顿挫。用户验收通过。

---

## 问题二：流式回复时回看历史被顶走（「正在回复的框越来越长」）

### 2.1 症状与根因

架构：`Column = [Expanded(reverse 列表), 流式面板, 队列条, 输入栏]`——流式行渲染在**列表外**的面板里（这半步是对的：列表内容流式期间零变化）。

**但面板没有高度约束**。于是：

- 面板每长一寸 → `Expanded` 给列表的 viewport 高度被压矮一寸 → 停在历史区的用户被持续顶向最新端；
- 「框越来越长」和「人被往回拉」是**同一个物理过程**；
- 「往回滑不动」也是它：滑多少被顶回多少。

> 调研原话级结论：**视口不被拉走靠「布局总高恒定」（Telegram 钳制流式 cell 到剩余视口 /
> LobeChat spacer 收缩吸收），而不是靠滚动补偿。** 滚动补偿救不了布局挤压。

### 2.2 业界调研（GitHub 源码取证）

| 项目 | 机制 |
|---|---|
| **Telegram Android**（标杆） | `ChatActivityDraftMessageMeasureController`：流式 cell 测量高被钳制为 `max(内容自然高, 剩余视口高)`——多出的高度是 **padding 不是 reflow**，内容在槽位内生长，**RecyclerView 总高不变，scroll offset 在数学上不可能移动**；内容超出剩余空间/滚出视口才释放钳制；钳制期内 PageDown 按钮不显示 |
| **Open WebUI** | 单一 `autoScroll` 布尔态，每次滚动事件重算（`scrollHeight - scrollTop <= clientHeight + 5`，**自愈式**：程序化回底过同一 handler 到底自动恢复 true）；流式跟滚 rAF 节流；`scrollToBottom` 双 rAF 落底（估算高度会漂移，注释原话 "re-scroll across two animation frames to land at the true bottom"）；**流式完成时的滚动同样过闸门**，回看中完成不拽人 |
| **LobeChat**（最精细） | spacer 方案：发送后在流式消息后追加合成行撑满视口、钉住用户消息，流式长高全靠 spacer 收缩吸收→**总高恒等视口**；用户意图 TTL（pointerdown/touchmove/wheel 打 500ms 时间戳，窗内 scroll 才算用户行为——排除程序化滚动误判）；`overflowAnchor: none` 显式关浏览器锚定；流式行 keepMounted 不参与虚拟回收 |
| **NextChat** | 一帧滞后 tail -f：`detach`（已在底）跳过冗余滚动，chunk 溢出那帧「不再在底」→ 下次 render 自动重新钉底；移动端 `onTouchStart` 立即断跟，不让自动滚动和拖拽对打 |
| **Cline** | kill switch 是**普通 ref 非 state**（置位/复位不触发渲染，避免「取消跟随」本身引起抖动）；置 true 只认用户 wheel-up；恢复只认「手动滚回底部 / 新 turn / 用户动作」；跟随触发 effect 依赖列表长度而非内容长度（"so this doesn't fire while a message streams"），行高增长走 500ms debounce |
| **ChatGPT 网页**（交互基线） | tail -f：仅在底部才跟随；上滚即停、位置原样保留；悬浮 Jump to bottom。社区把「流式 auto-scroll 覆盖用户滚动位置」定性为 bug |

**共同设计原则**（五家收敛，无一例外）：

1. 流式增长被钳在**恒定布局预算**内（Telegram 槽位 / LobeChat spacer / Open WebUI 面板定高）；
2. 跟随唯一闸门：`atBottom && isGenerating && !userScrolling`，**每个流式 tick 重新求值**；
3. atBottom 阈值取小值（5~56px）；
4. 用户滚动判定要叠**显式手势信号**（dragDetails / pointer / wheel）+ isScrolling 静默窗，绝不能只靠 onScroll 位置回算（程序化 animateTo/jumpTo 会被误判成用户行为）；
5. 流式完成/正式入库的过渡：回看中**零动作**；在底部时「先插入正式 item、后卸载面板」同帧完成，高度差用锚点补偿。

### 2.3 修复方案（Flutter 化）

**① 面板高度钳制**（Telegram「流式槽位」的 Flutter 化）：

```dart
Container(
  constraints: BoxConstraints(
    // 最高 1/10 屏（用户最终裁定）：当「正在回复」进度条用，绝不挤压历史阅读。
    maxHeight: MediaQuery.sizeOf(context).height * 0.10,
  ),
  child: SingleChildScrollView(
    controller: _scrollCtrl,
    child: buildRowCard(...), // 流式 markdown 卡
  ),
)
```

- 内容低于上限：面板自然高度；超出：**内部滚动消化**，外部高度从此恒定 → 列表视口空间恒定 → 停在历史区钉死。

**② 面板内跟尾**（LLM UI 惯例 tail -f）：

```dart
@override
void didUpdateWidget(covariant _StreamingPanel old) {
  super.didUpdateWidget(old);
  if (_tailScheduled) return;          // 同帧去重：一帧至多一次（原则：跟尾要节流）
  _tailScheduled = true;
  WidgetsBinding.instance.addPostFrameCallback((_) {
    _tailScheduled = false;
    if (!mounted || !_followTail || !_scrollCtrl.hasClients) return;
    // 滚动进行中（拖拽/惯性）绝不 jump——跟随与手势对打是「滑不动」的来源。
    if (_scrollCtrl.position.isScrollingNotifier.value) return;
    final pos = _scrollCtrl.position;
    if (pos.maxScrollExtent - pos.pixels > 1) _scrollCtrl.jumpTo(pos.maxScrollExtent);
  });
}

bool _onScrollNotification(ScrollNotification n) {
  if (n is ScrollEndNotification && _scrollCtrl.hasClients) {
    final pos = _scrollCtrl.position;
    final away = pos.maxScrollExtent - pos.pixels > 48; // 业界阈值 5~56px 取 48
    if (away != _followTail) setState(() => _followTail = away); // 上滑回看即停，贴底恢复
  }
  return false;
}
```

**③ 兄弟面板同治理**：交互审批面板同样封顶（70% 屏 + 内部滚动）——多问题堆叠时不再无限吃列表空间。

**④ 列表侧零改动**：FollowLock（用户主动滚离→锁存停止跟随，主动滚回最新端→解锁）+ 问题一的锚行补偿，已覆盖「停在历史区钉住」与「流式结束面板卸载、列表扩张」的过渡（锚行补偿会把这次视口扩张引起的位移也钉回去）。

**回底按钮语义**（各项目一致，我们已经做对）：显示条件 `!atBottom`；动作 = 回底 + **恢复跟随**；点击后未读徽标清零。

### 2.4 效果

流式输出中往回滑顺畅无顶推；停在历史区等到回复完成视口不动；长回复时面板恒定 1/10 屏、内部自动跟最新输出、上滑可回看本条已输出部分；回复完成面板消失瞬间不跳。用户验收「解决得非常完美」。

---

## 附：可直接落地的检查清单

**滚动锚定（治「飘」）**

- [ ] 锚定单位 = 可见行的（身份， 视口内位置），delta = 锚行 y 差，不使用总高/extent 增量
- [ ] 锚行身份变化（翻页/重同步/滑出）→ 重定基线不补，替代一切散装断补标记
- [ ] 滚动事件里实时刷新锚基线（程序化滚动与用户滚动都不进补偿）
- [ ] 补偿走合并桶 + 小阈值过滤 + 单步上限 + 短动画 + 单飞锁；拖拽/惯性中静默
- [ ] cacheExtent 250 → 视口 2~3 倍
- [ ] 行高尽量确定：图片预知尺寸占位（三家聊天 App 全部把媒体尺寸写进消息元数据）
- [ ] 回底按钮 = 回底 + 恢复跟随 + 清未读；贴底判定阈值：主列表可取 40~180px 滞回，面板内 5~56px

**流式回看（治「顶」）**

- [ ] 流式内容锁定在恒定布局预算内（面板 maxHeight / 槽位 / spacer），超出内部滚动
- [ ] 跟随闸门 `atBottom && isGenerating && !userScrolling` 每 tick 重判
- [ ] 用户手势显式信号（dragDetails/pointer/wheel）+ isScrolling 静默窗，程序化滚动不误判
- [ ] 跟尾节流（每帧至多一次）+ post-frame 量尺寸
- [ ] 流式完成过渡：回看中零动作；在底部时先插入后卸载、同帧完成

**框架层认知（Flutter）**

- [ ] 无 scroll anchoring（#99158 open），别等；`jumpTo` 像素补偿五宗罪（值未知/晚一帧/估算误差/同帧竞态/与手势打架）
- [ ] `RenderSliverList` 视口外高度靠 dead reckoning 估算，修正即跳动
- [ ] `RangeMaintainingScrollPhysics` 在 reverse+插入场景有已知 bug（#155152），别指望它保稳
- [ ] 要 index 定位再考虑 scrollable_positioned_list（原仓库已归档，Stream fork 是活跃维护版），但注意 prepend 时 index 平移——必须叠「按 key 找回锚点」

## 参考（本次调研实读的源码位置）

- Telegram Android：`TMessagesProj/.../ui/ChatActivity.java`（scrollToMessageId L16801、翻页保位 L21385、贴底判定 L26044）、`Components/chat/ChatActivityDraftMessageMeasureController.java`（108 行，流式钳制全文）
- Telegram Desktop：`Telegram/SourceFiles/history/view/history_view_list_widget.cpp`（ScrollTopState、save/restoreScrollState）
- Signal Android v6.30：`androidx/recyclerview/widget/ConversationLayoutManager.kt`、`ConversationFragment.kt`（isScrolledToBottom/scroll button）、`components/ScrollToPositionDelegate.kt`
- Element Android：`ScrollOnNewMessageCallback.kt`、`ScrollOnHighlightedEventCallback.kt`
- Stream Chat Flutter：`packages/stream_chat_flutter/lib/scrollable_positioned_list/`（fork）、`src/message_list_view/`（message_list_view / auto_scroll_policy / mlv_utils）
- Open WebUI：`src/lib/components/chat/Chat.svelte`、`Messages.svelte`
- LobeChat：`src/features/Conversation/ChatList/`（VirtualizedList / useConversationScroll / AutoScroll / BackBottom）
- NextChat：`app/components/chat.tsx`
- Cline：`apps/vscode/webview-ui/src/components/chat/chat-view/`（useScrollBehavior / MessagesArea）
- Flutter 框架：`rendering/sliver_list.dart`（dead reckoning 原文）、`widgets/scroll_position.dart`（correctForNewDimensions）、issues #99158 / #1710 / #12319 / #155152 / PR #178021
