/// `zcode-task` 通道 — 任务（会话）管理。
/// 移植自 `lib/protocol/conversation.dart` + `lib/state/app_controller.dart`。
///
/// ⚠️ **版本敏感**：桌面端**自动升级**过，`prepareWorkspace(scope)` 已被移除
/// （调用即 `Method not found`），新版是 `getTaskConfigOptions({taskId})`。
/// 客户端必须对每个方法都能优雅降级——这不是防御性编程，是实测教训。

import type { Bridge } from './remoteSession'
import { Chan } from './constants'

/** 列表类调用超时（Flutter 同值）：慢但会回，别用默认 30s 拖住 UI。 */
const LIST_TIMEOUT_MS = 12_000

export class TaskChannel {
  constructor(
    private bridge: Bridge,
    private onLog?: (line: string) => void,
  ) {}

  private get ch() {
    return this.bridge.channels
  }

  private get scope() {
    return this.bridge.scope
  }

  /** 会话列表（含归档项，调用方需按 `archived`/`deleted` 过滤）。 */
  async listTasks(): Promise<unknown> {
    return this.ch.call(Chan.task, 'listTasks', [this.scope], LIST_TIMEOUT_MS)
  }

  /** 置顶列表——**置顶状态的唯一权威**（listTasks 不带置顶）。 */
  async listPinnedTasks(): Promise<unknown> {
    return this.ch.call(Chan.task, 'listPinnedTasks', [this.scope], LIST_TIMEOUT_MS)
  }

  async listArchivedTasks(): Promise<unknown> {
    return this.ch.call(Chan.task, 'listArchivedTasks', [this.scope], LIST_TIMEOUT_MS)
  }

  /** 每会话 token 消耗（列表角标）。 */
  async getTaskTokenUsage(): Promise<unknown> {
    return this.ch.call(Chan.task, 'getTaskTokenUsage', [this.scope], LIST_TIMEOUT_MS)
  }

  /**
   * 模型 / 模式 / 思考等级选项（`prepareWorkspace` 的接替者）。
   * 返回选项组数组：`[{id:'model'|'mode'|'thought_level', currentValue, options:[...]}]`。
   * 注意 `id` 是 `thought_level`（下划线），别写成 `thoughtLevel`。
   */
  async getTaskConfigOptions(taskId: string): Promise<unknown> {
    return this.ch.call(Chan.task, 'getTaskConfigOptions', [{ taskId }], 20_000)
  }

  async setTaskPinned(taskId: string, pinned: boolean): Promise<unknown> {
    return this.ch.call(Chan.task, 'setTaskPinned', [{ ...this.scope, taskId, pinned }])
  }

  async renameTask(taskId: string, title: string): Promise<unknown> {
    return this.ch.call(Chan.task, 'renameTask', [{ ...this.scope, taskId, title }])
  }

  async archiveTask(taskId: string): Promise<unknown> {
    return this.ch.call(Chan.task, 'archiveTask', [{ ...this.scope, taskId }])
  }

  async unarchiveTask(taskId: string): Promise<unknown> {
    return this.ch.call(Chan.task, 'unarchiveTask', [{ ...this.scope, taskId }])
  }

  /**
   * 删除任务。
   * ⚠️ 调用方应先 best-effort `stop` 运行中的会话——否则 agent 会继续跑完
   * 白烧 token（BUG-23，用户点名）。这里不代劳，因为 stop 要会话上下文。
   */
  async deleteTask(taskId: string): Promise<unknown> {
    return this.ch.call(Chan.task, 'deleteTask', [{ ...this.scope, taskId }])
  }

  log(line: string): void {
    this.onLog?.(line)
  }
}
