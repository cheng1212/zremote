import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 本地通知薄封装：任务完成/中断/报错/等待确认时弹系统通知。
/// 仅即时通知，无定时/无后台 dart 回调——App 被杀后收不到（无推送服务）。
class NotificationService {
  NotificationService._();

  static final FlutterLocalNotificationsPlugin _plugin =
      FlutterLocalNotificationsPlugin();
  static bool _ready = false;

  /// 通知总开关：持久化（维度4 盘点发现重启后回默认 true，用户关了又响）。
  static bool _enabled = true;
  static bool get enabled => _enabled;
  static set enabled(bool v) {
    _enabled = v;
    _persist('notificationsEnabled', v);
  }

  // ---------------------------------------------- 通知类型（铃声/震动）

  /// 提示音开关（系统默认铃声）。旧字段 notificationSoundMode 迁移：
  /// 'silent' → soundOn=false。
  static bool _soundOn = true;
  static bool get soundOn => _soundOn;
  static set soundOn(bool v) {
    _soundOn = v;
    _persist('notifSoundOn', v);
  }

  /// 震动开关。
  static bool _vibrateOn = true;
  static bool get vibrateOn => _vibrateOn;
  static set vibrateOn(bool v) {
    _vibrateOn = v;
    _persist('notifVibrateOn', v);
  }

  static Future<void> _persist(String key, bool v) async {
    try {
      final sp = await SharedPreferences.getInstance();
      await sp.setBool(key, v);
    } on Object {
      // 持久化失败不影响本次会话内生效
    }
  }

  // Android 渠道建后声音/震动属性不可改——按 铃声×震动 组合预建四渠道，
  // 发通知时按当前开关选渠道，切换即时生效。重要性都是 high：横幅弹窗
  // 始终有，用户配置的只是响不响、震不震。
  static const _channels = <String,
      ({String id, String name, bool sound, bool vibrate})>{
    'sv': (
      id: 'task_events_sv',
      name: '任务事件（铃声+震动）',
      sound: true,
      vibrate: true,
    ),
    's': (id: 'task_events_s', name: '任务事件（仅铃声）', sound: true, vibrate: false),
    'v': (id: 'task_events_v', name: '任务事件（仅震动）', sound: false, vibrate: true),
    'none': (id: 'task_events_none', name: '任务事件（静默）', sound: false, vibrate: false),
  };

  static ({String id, String name, bool sound, bool vibrate}) _channel() {
    final key = '${_soundOn ? 's' : ''}${_vibrateOn ? 'v' : ''}';
    return _channels[_channels.containsKey(key) ? key : 'none']!;
  }

  /// 点通知的跳转回调（sessionId, title）——main.dart 里接到 ChatPage 导航。
  /// App 进程被杀后点通知冷启动的那次回调拿不到（无后台 isolate），已知限。
  static void Function(String sessionId, String title)? onTap;

  static void _handleTap(NotificationResponse resp) {
    final p = resp.payload ?? '';
    final i = p.indexOf('|');
    if (i <= 0) return;
    final sid = p.substring(0, i);
    final title = p.substring(i + 1);
    if (sid.isNotEmpty) onTap?.call(sid, title);
  }

  /// main() 里 unawaited 调用；失败静默（通知是锦上添花，不能挡启动）。
  static Future<void> init() async {
    if (_ready) return;
    try {
      const android = AndroidInitializationSettings('ic_launcher');
      const settings = InitializationSettings(android: android);
      await _plugin.initialize(
        settings,
        onDidReceiveNotificationResponse: _handleTap,
      );
      final impl = _plugin
          .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin
          >();
      await impl?.requestNotificationsPermission();
      for (final c in _channels.values) {
        await impl?.createNotificationChannel(
          AndroidNotificationChannel(
            c.id,
            c.name,
            importance: Importance.high,
            playSound: c.sound,
            enableVibration: c.vibrate,
          ),
        );
      }
      final sp = await SharedPreferences.getInstance();
      _enabled = sp.getBool('notificationsEnabled') ?? true;
      // 旧提示音模式迁移：'silent' → 只关铃声；无旧字段用新键。
      final legacy = sp.getString('notificationSoundMode');
      _soundOn = legacy != null
          ? legacy != 'silent'
          : (sp.getBool('notifSoundOn') ?? true);
      _vibrateOn = sp.getBool('notifVibrateOn') ?? true;
      _ready = true;
    } on Object {
      _ready = false;
    }
  }

  /// [title] 形如「任务完成 · 会话名」。重复弹同 ID 会覆盖上一条（合理）。
  /// [detail] 具体原因（如「余额不足（HTTP 402）」），追加在提示语之后；
  /// [sessionId]+[title] 编成 payload，点通知跳对应会话。
  static Future<void> showTaskEvent({
    required int id,
    required String title,
    required String body,
    String? detail,
    String? sessionId,
  }) async {
    if (!_ready || !enabled) return;
    try {
      final ch = _channel();
      final fullBody = (detail == null || detail.isEmpty)
          ? body
          : '$body\n$detail';
      final details = NotificationDetails(
        android: AndroidNotificationDetails(
          ch.id,
          ch.name,
          importance: Importance.high,
          priority: Priority.high,
          playSound: ch.sound,
          enableVibration: ch.vibrate,
          // 锁屏完整显示（用户场景：锁屏看得到任务完成/报错）。
          visibility: NotificationVisibility.public,
          // 展开态正文必须挂在这里：flutter_local_notifications 一旦给了
          // styleInformation，展开布局就只读它的 content——传空串会让
          // 用户展开通知看到一片空白（BUG-22）。
          styleInformation: BigTextStyleInformation(fullBody),
        ),
      );
      await _plugin.show(
        id,
        title,
        fullBody,
        details,
        payload: sessionId == null ? null : '$sessionId|$title',
      );
    } on Object {
      // 静默：通知失败不影响主流程
    }
  }
}
