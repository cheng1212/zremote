<script setup lang="ts">
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
  min-height: 100vh;
  display: flex;
  flex-direction: column;
}
</style>
