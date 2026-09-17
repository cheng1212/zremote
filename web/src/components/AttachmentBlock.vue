<script setup lang="ts">
/// 附件块 —— 图片回显 / 文件 chip。
///
/// ⚠️ 图片字节**必须走协议取**（`attachmentReadV4`）：浏览器读不到本地路径
/// （`D:\…` 打不开、`file://` 加载不了）。取回后存成 blob URL 显示，
/// 缓存命中就不重复拉（见 `lib/blobCache.ts`）。
///
/// 失败要**显式回显原因**，不能留个空白占位——用户会以为消息丢了。

import { computed, onMounted, ref, watch } from 'vue'
import { useAppStore } from '../stores/app'
import { attachmentLabel, isImageAttachment, type AttItem } from '../lib/attachments'
import { formatBytes } from '../lib/upload'

const props = defineProps<{
  attachment: AttItem
  /** 同一条消息里的全部图片（点开可左右翻）。 */
  gallery?: AttItem[]
}>()

const app = useAppStore()

const isImage = computed(() => isImageAttachment(props.attachment))
const label = computed(() => attachmentLabel(props.attachment))
const sizeText = computed(() => (props.attachment.size ? formatBytes(props.attachment.size) : ''))
const url = computed(() => app.attachmentUrls[props.attachment.ref] ?? '')
const loading = computed(() => app.attachmentLoading[props.attachment.ref] === true)
const error = computed(() => app.attachmentErrors[props.attachment.ref] ?? '')
/** mime 认不出 + 不是图片扩展名时，字节到手才知道是不是图（魔数补判）。 */
const sniffedImage = ref(false)
const zoom = ref(false)

async function load(): Promise<void> {
  if (!props.attachment.ref) return
  const u = await app.loadAttachment(props.attachment.ref)
  if (u && !isImage.value) {
    // 取回来才发现是图（相册无后缀图常见）——按图显示
    sniffedImage.value = true
  }
}

onMounted(() => {
  if (isImage.value) void load()
})

watch(
  () => props.attachment.ref,
  () => {
    sniffedImage.value = false
    if (isImage.value) void load()
  },
)

const showAsImage = computed(() => isImage.value || sniffedImage.value)

function openZoom(): void {
  if (!url.value) return
  zoom.value = true
}
</script>

<template>
  <!-- 单一根节点：组件用在 v-for 里，多根会触发 key/透传告警 -->
  <div class="att">
    <!-- 图片：独立块，等比、限高 -->
    <template v-if="showAsImage">
      <div class="img-block">
        <div v-if="loading" class="img-ph">正在取回图片…</div>
        <button v-else-if="url" type="button" class="img-btn" @click="openZoom">
          <img :src="url" :alt="label" class="img" />
        </button>
        <div v-else-if="error" class="img-err">
          图片读取失败：{{ error }}
          <button type="button" class="retry" @click="load">重试</button>
        </div>
        <div v-else class="img-ph">{{ label }}</div>
      </div>
    </template>

    <!-- 非图片：文件 chip -->
    <template v-else>
      <div class="file-chip" :title="attachment.ref">
        <span class="file-chip__name">{{ label }}</span>
        <span v-if="sizeText" class="file-chip__size">{{ sizeText }}</span>
        <span v-if="loading" class="file-chip__state">读取中…</span>
        <span v-else-if="error" class="file-chip__err">{{ error }}</span>
      </div>
    </template>

    <!-- 全屏查看（点空白关闭） -->
    <div v-if="zoom && url" class="zoom" role="presentation" @click="zoom = false">
      <img :src="url" :alt="label" class="zoom__img" />
      <button type="button" class="zoom__close" aria-label="关闭" @click.stop="zoom = false">
        ×
      </button>
    </div>
  </div>
</template>

<style scoped>
.att {
  display: flex;
  flex-direction: column;
  align-items: flex-end;
  max-width: 100%;
}
.img-block {
  margin-top: 8px;
  display: flex;
  justify-content: flex-end;
}
.img-btn {
  padding: 0;
  border: none;
  background: none;
  cursor: zoom-in;
  line-height: 0;
}
.img {
  max-width: min(72vw, 320px);
  max-height: 300px;
  width: auto;
  height: auto;
  border-radius: 10px;
  display: block;
}
.img-ph,
.img-err {
  max-width: min(72vw, 320px);
  padding: 12px 14px;
  font-size: 12px;
  color: var(--ink-faint);
  background: var(--surface);
  border: 1.3px dashed var(--line);
  border-radius: 10px;
}
.img-err {
  color: var(--rose);
  border-color: var(--rose);
  border-style: solid;
}
.retry {
  margin-left: 8px;
  font: inherit;
  font-size: 12px;
  font-weight: 800;
  color: inherit;
  background: none;
  border: 1.2px solid currentColor;
  border-radius: 999px;
  padding: 1px 9px;
  cursor: pointer;
}
.file-chip {
  display: inline-flex;
  align-items: center;
  gap: 8px;
  max-width: 100%;
  margin-top: 6px;
  padding: 7px 11px;
  font-size: 12.5px;
  background: var(--surface);
  border: 1.4px solid var(--line);
  border-radius: 10px;
}
.file-chip__name {
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
  max-width: 220px;
  font-weight: 700;
}
.file-chip__size {
  flex: none;
  color: var(--ink-faint);
  font-size: 11px;
}
.file-chip__state {
  flex: none;
  color: var(--ink-faint);
  font-size: 11px;
}
.file-chip__err {
  flex: none;
  color: var(--rose);
  font-size: 11px;
}
.zoom {
  position: fixed;
  inset: 0;
  z-index: 50;
  background: rgba(36, 28, 21, 0.92);
  display: flex;
  align-items: center;
  justify-content: center;
  padding: 20px;
}
.zoom__img {
  max-width: 100%;
  max-height: 100%;
  object-fit: contain;
  border-radius: 8px;
}
.zoom__close {
  position: absolute;
  top: 16px;
  right: 16px;
  width: 40px;
  height: 40px;
  font-size: 24px;
  line-height: 1;
  color: #fff;
  background: rgba(255, 255, 255, 0.14);
  border: none;
  border-radius: 50%;
  cursor: pointer;
}
</style>
