<script setup lang="ts">
/// 根组件 —— 三段路由：未连上 → 配对页；已连上 → 会话列表 / 聊天页。
///
/// 移动端布局要点：`100dvh` 而不是 `100vh`（移动浏览器地址栏收起/展开会改
/// 视口高度，`100vh` 会把底部输入框顶出屏幕），并让 shell 撑满高度、
/// 内部各页自己管滚动区（`min-height: 0` 是 flex 子项能收缩的关键）。
import { useAppStore } from './stores/app'
import PairView from './views/PairView.vue'
import SessionsView from './views/SessionsView.vue'
import ChatView from './views/ChatView.vue'

const app = useAppStore()
</script>

<template>
  <PairView v-if="!app.showMainShell" />
  <div v-else class="shell">
    <SessionsView v-if="!app.chat" />
    <ChatView v-else />
  </div>
</template>

<style scoped>
.shell {
  height: 100dvh;
  display: flex;
  flex-direction: column;
  min-height: 0;
  overflow: hidden;
}
</style>
