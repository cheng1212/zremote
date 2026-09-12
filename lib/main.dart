import 'dart:async';
import 'dart:io' show stderr;

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';

import 'services/notification_service.dart';
import 'state/app_controller.dart';
import 'theme.dart';
import 'ui/chat_page.dart';
import 'ui/pair_page.dart';
import 'ui/profile_page.dart';
import 'ui/tasks_page.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  // 诊断：release 包里 Flutter 默认只往 logcat 打一行异常壳
  // （"Another exception was thrown: Instance of 'DiagnosticsProperty<void>'"），
  // 首异常正文与堆栈全部丢失——真机排查无从下手。
  // 这里把完整首异常写到 stderr（→ logcat 的 "System.err"），
  // 与 logcat 的 I/flutter 区分开，便于取证。
  FlutterError.onError = (FlutterErrorDetails details) {
    FlutterError.presentError(details);
    try {
      stderr.writeln('[zremote-exc] ${details.exception}');
      stderr.writeln('[zremote-exc-library] ${details.library}');
      stderr.writeln('[zremote-exc-context] ${details.context}');
      stderr.writeln('[zremote-exc-stack] ${details.stack}');
    } on Object {
      // 诊断通道本身不能拖垮 App
    }
  };
  unawaited(NotificationService.init());
  runApp(const ZRemoteApp());
}

class ZRemoteApp extends StatefulWidget {
  const ZRemoteApp({super.key});

  @override
  State<ZRemoteApp> createState() => _ZRemoteAppState();
}

class _ZRemoteAppState extends State<ZRemoteApp> with WidgetsBindingObserver {
  final ZApp _app = ZApp();
  final _navigatorKey = GlobalKey<NavigatorState>();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _app.addListener(_notify);
    // 点任务通知 → 跳对应会话（与任务卡点击同一条导航路径）。
    NotificationService.onTap = (sessionId, title) {
      if (!_app.showMainShell) return; // 还没连上桌面端，跳了也是空页
      _app.openSession(sessionId).catchError((Object e) {
        _app.log('[app] 通知跳转打开会话失败: $e');
      });
      _navigatorKey.currentState?.push(
        MaterialPageRoute(
          builder: (_) => ChatPage(app: _app, sessionId: sessionId, title: title),
        ),
      );
    };
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // 切回前台立即探测链路；被系统掐死的 socket 马上重连，
    // 不等心跳超时。
    if (state == AppLifecycleState.resumed) {
      _app.pokeRelay();
    }
  }

  void _notify() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'zremote',
      debugShowCheckedModeBanner: false,
      navigatorKey: _navigatorKey,
      theme: ZT.theme(),
      // 文本操作菜单（复制/全选/粘贴）走系统本地化——中文界面就得是中文菜单。
      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      supportedLocales: const [Locale('zh'), Locale('en')],
      locale: const Locale('zh'),
      // 首屏由状态推导（判定见 ZApp.showMainShell）：有内容、或正在就地重连，
      // 就进主壳。「重新连接 / 断开连接」都不再把用户甩回配对页——要回配对页
      // 走抽屉里的「去连接」。不用单向闩——那会让断开后困在空任务页。
      home: _app.showMainShell
          ? HomeShell(
              app: _app,
              onOpenTask: (sessionId, title) {
                _app.openSession(sessionId).catchError((Object e) {
                  _app.log('[app] 打开任务失败: $e');
                });
                _navigatorKey.currentState?.push(
                  MaterialPageRoute(
                    builder: (_) =>
                        ChatPage(app: _app, sessionId: sessionId, title: title),
                  ),
                );
              },
              onNewChat: () {
                _app.newDraft();
                _navigatorKey.currentState?.push(
                  MaterialPageRoute(
                    builder: (_) =>
                        ChatPage(app: _app, sessionId: null, title: '新对话'),
                  ),
                );
              },
            )
          : PairPage(app: _app),
    );
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _app.removeListener(_notify);
    _app.dispose();
    super.dispose();
  }
}

/// 配对后的主壳：底部导航（会话 / 我的）。
/// 「项目」无对应接口未做；ChatPage 走全屏路由，不受 tab 影响。
class HomeShell extends StatefulWidget {
  final ZApp app;
  final void Function(String sessionId, String title) onOpenTask;
  final VoidCallback onNewChat;

  const HomeShell({
    super.key,
    required this.app,
    required this.onOpenTask,
    required this.onNewChat,
  });

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  int _tab = 0;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: IndexedStack(
        index: _tab,
        children: [
          TasksPage(
            app: widget.app,
            onOpenTask: widget.onOpenTask,
            onNewChat: widget.onNewChat,
          ),
          ProfilePage(app: widget.app),
        ],
      ),
      bottomNavigationBar: Container(
        decoration: const BoxDecoration(
          color: ZT.surface,
          border: Border(top: BorderSide(width: 1.4, color: ZT.line)),
        ),
        child: SafeArea(
          child: Row(
            children: [
              _tabItem(index: 0, icon: Icons.forum_rounded, label: '会话'),
              _tabItem(index: 1, icon: Icons.person_rounded, label: '我的'),
            ],
          ),
        ),
      ),
    );
  }

  Widget _tabItem({
    required int index,
    required IconData icon,
    required String label,
  }) {
    final selected = _tab == index;
    final color = selected ? ZT.primary : ZT.inkFaint;
    return Expanded(
      child: InkWell(
        onTap: () => setState(() => _tab = index),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 7),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 22, color: color),
              const SizedBox(height: 2),
              Text(
                label,
                style: TextStyle(
                  fontSize: 10.5,
                  fontWeight: FontWeight.w800,
                  color: color,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
