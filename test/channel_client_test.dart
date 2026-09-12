import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:zremote/protocol/channel_client.dart';
import 'package:zremote/protocol/constants.dart';
import 'package:zremote/protocol/value_codec.dart';

/// 构造一条 Channel IPC 帧：header [+ data]。
Uint8List frame(Object header, [Object? arg]) {
  final w = ValueWriter();
  w.writeValue(header);
  if (arg != null) w.writeValue(arg);
  return w.take();
}

void main() {
  test('dispose 补完在途调用：立刻报 StateError，不再干等超时', () async {
    final ch = ChannelClient(sendBody: (_) {});
    ch.handleMessage(frame([ipcResInitialize]));
    await ch.ready;
    final pending = ch.call('conv', 'rows', []);
    // 让 call 里 await ready 的微任务先跑完、补完器登记进 pending。
    await Future<void>.delayed(Duration.zero);
    ch.dispose();
    await expectLater(
      pending,
      throwsStateError,
    ).timeout(const Duration(seconds: 3));
  });

  test('dispose 后正常响应路径不受影响的调用仍可发起并等到回包（回归）', () async {
    final sent = <Uint8List>[];
    final ch = ChannelClient(sendBody: sent.add);
    ch.handleMessage(frame([ipcResInitialize]));
    await ch.ready;
    final pending = ch.call('conv', 'rows', []);
    await Future<void>.delayed(Duration.zero);
    // 从请求帧抠出 requestId，回一份成功响应。
    final reader = ValueReader(sent.single);
    final header = reader.readValue() as List;
    final id = header[1] as int;
    ch.handleMessage(frame([ipcResPromiseSuccess, id], 'ok'));
    expect(await pending, 'ok');
    ch.dispose();
  });
}
