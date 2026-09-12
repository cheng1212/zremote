/// ZCode Remote v4 protocol constants.
///
/// 防锈设计：智谱更新时优先核对/修改这一个文件。
/// 规格来源：docs/API.md（逆向自官方客户端 + 生产实测）。
library;

import 'dart:math';

import 'package:flutter/foundation.dart';

/// auth_init meta.platform 用的客户端平台名。
String get platformName {
  if (kIsWeb) return 'web';
  return switch (defaultTargetPlatform) {
    TargetPlatform.windows => 'windows',
    TargetPlatform.macOS => 'macos',
    TargetPlatform.linux => 'linux',
    TargetPlatform.android => 'android',
    TargetPlatform.iOS => 'ios',
    _ => 'unknown',
  };
}

/// --- L1 relay ---------------------------------------------------------
const relayHeartbeatInterval = Duration(seconds: 10);
const relayHeartbeatAckTimeout = Duration(seconds: 30);
const relayWaitingTimeout = Duration(seconds: 30);
const relayReconnectMaxBackoffMs = 15000;

/// --- L2 signaling ----------------------------------------------------
const sigBootstrap = 'bootstrap-request';
const sigBootstrapResponse = 'bootstrap-response';
const sigWorkspaceList = 'workspace-list-request';
const sigWorkspaceListResponse = 'workspace-list-response';
const sigBridgeOpen = 'workspace-bridge-open';
const sigBridgeReady = 'workspace-bridge-ready';
const sigBridgeError = 'workspace-bridge-error';
const sigBridgeReconnect = 'workspace-reconnect-request';
const sigBridgeReconnectResponse = 'workspace-reconnect-response';
const sigViewStateUpdate = 'mobile-view-state-update';
const pushWorkspaceListUpdated = 'workspace-list-updated';
const pushBridgeDegraded = 'bridge-degraded';

/// --- L3 rpc-frame ----------------------------------------------------
const rpcFrameMaxFragmentPayloadBytes = 512 * 1024;
const rpcFrameMaxMessageBytes = 16 * 1024 * 1024;
const rpcFrameMaxFragments = 64;

/// --- L4 channel IPC --------------------------------------------------
const ipcReqPromise = 100;
const ipcReqPromiseCancel = 101;
const ipcReqEventListen = 102;
const ipcReqEventDispose = 103;

const ipcResInitialize = 200;
const ipcResPromiseSuccess = 201;
const ipcResPromiseError = 202;
const ipcResPromiseErrorObj = 203;
const ipcResEventFire = 204;

/// 退订（unsubscribe）用的短超时。
///
/// 退订是**尽力而为**的收尾动作：把订阅从服务端摘掉是好事，但摘不掉也不该
/// 影响本地拆栈。而 `ChannelClient.call` 的默认超时是 30s，链路僵死（中继心跳
/// ack 超时前的那段窗口）时"chat 退订 + index 退订"会串行等满 60s，用户看到的
/// 就是切项目白屏几十秒。这里给一个短上限：发出去就行，收不到回执也不影响拆栈。
const ipcUnsubscribeTimeout = Duration(milliseconds: 1500);

/// --- L5 channels -----------------------------------------------------
class Chan {
  static const agent = 'zcode-agent';
  static const task = 'zcode-task';
  static const session = 'zcode-session';
  static const file = 'file';
  static const system = 'system';
  static const terminal = 'terminal';
  static const git = 'git';
  static const gitCheckpoint = 'git-checkpoint';
  static const setting = 'setting';
  static const credential = 'credential';
  static const broadcast = 'broadcast';
  static const fileWatcher = 'file-watcher';
  static const oauth = 'oauth';
  static const modelProvider = 'model-provider';
  static const usageStats = 'usage-stats';
  static const codingPlanSubscription = 'coding-plan-subscription';
  static const skills = 'skills';
  static const skillSync = 'skill-sync';
  static const mcpSync = 'mcp-sync';
  static const pluginSync = 'plugin-sync';
  static const plugins = 'plugins';
  static const pluginManagement = 'plugin-management';
  static const subagents = 'subagents';
  static const commands = 'commands';
  static const hooks = 'hooks';
  static const memory = 'memory';
  static const outputStyle = 'output-style';
  static const settingsSync = 'settings-sync';
  static const bots = 'bots';
  static const feedback = 'feedback';
  static const repoWiki = 'repo-wiki';
  static const promptAttachmentTransfer = 'prompt-attachment-transfer';
  static const offPeakTask = 'off-peak-task';
}

/// --- Conversation V4 -------------------------------------------------
const convChannel = Chan.agent;
const convProtocolVersion = 3;
const convProtocolAppVersion = '3.6.5';
const convClientKind = 'mobileApp';

const mHello = 'helloConversationV4';
const mInitialize = 'initializeConversationV4';
const mSendCommand = 'sendConversationCommandV4';
const mSubscribeConv = 'subscribeConversationV4';
const mUnsubscribeConv = 'unsubscribeConversationV4';
const mResyncConv = 'resyncConversationV4';
const mSubscribeIndex = 'subscribeSessionsIndexV4';
const mUnsubscribeIndex = 'unsubscribeSessionsIndexV4';
const mResyncIndex = 'resyncSessionsIndexV4';
const evConvFrame = 'onDynamicConversationFrame';
const evIndexFrame = 'onDynamicSessionsIndexFrame';
const mRowsRange = 'conversationRowsRangeV4';
const mPlans = 'conversationPlansV4';
const mFileChanges = 'conversationFileChangesV4';
const mFileRewindPreview = 'conversationFileRewindPreviewV4';
const mAttachmentBegin = 'attachmentBeginV4';
const mAttachmentChunk = 'attachmentChunkV4';
const mAttachmentCommit = 'attachmentCommitV4';
const mAttachmentRead = 'attachmentReadV4';

const mPrepareWorkspace = 'prepareWorkspace';

/// Commands that require baseRevision (optimistic concurrency).
const casCommands = <String>{
  'applyFileRewind',
  'forkAssistant',
  'editUserQuery',
  'retryTurn',
  'setAssistantFeedback',
  'sendQueuedNow',
  'editQueueItem',
  'reorderQueueItem',
  'deleteQueueItem',
  'setAutoDrain',
  'switchModelConfig',
  'switchCollaborationMode',
  'setFollowupMode',
  'pauseGoal',
  'resumeGoal',
};

/// CAS commands that additionally require baseLogEpoch.
const rowTargetCommands = <String>{
  'applyFileRewind',
  'forkAssistant',
  'editUserQuery',
  'retryTurn',
  'setAssistantFeedback',
};

/// Attachment chunking.
const attachmentChunkBytes = 384 * 1024;

/// RFC4122-ish v4 uuid（附件 uploadId 等本地生成标识用）。
String genUuid() {
  final r = Random.secure();
  final b = List<int>.generate(16, (_) => r.nextInt(256));
  b[6] = (b[6] & 0x0f) | 0x40;
  b[8] = (b[8] & 0x3f) | 0x80;
  String hex(int i) => b[i].toRadixString(16).padLeft(2, '0');
  final sb = StringBuffer();
  for (var i = 0; i < 16; i++) {
    if (i == 4 || i == 6 || i == 8 || i == 10) sb.write('-');
    sb.write(hex(i));
  }
  return sb.toString();
}

int _genIdCounter = 0;

/// 本地唯一 id：前缀-时间戳-进程内序号（clientId / commandId / requestId 用）。
/// 唯一性方案只在这一处，防碰撞加固改这里即可。
String genId(String prefix) =>
    '$prefix-${DateTime.now().microsecondsSinceEpoch}-${_genIdCounter++}';
