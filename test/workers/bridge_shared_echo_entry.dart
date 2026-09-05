// SharedWorker fixture for IsolateBridge browser tests.

import 'dart:async';
import 'dart:js_interop';

import 'package:isolate_manager/isolate_manager.dart';
import 'package:web/web.dart';

var _connections = 0;

Future<void> main() => isolateBridgeSharedWorkerMain<Object?, Object?>(
  (controller, initialParams) async {
    _connections++;
    controller
      ..initialized()
      ..send(<String, Object?>{
        'type': 'connected',
        'connections': _connections,
        'initial': initialParams,
      });
    controller.messages.listen((message) {
      controller.send(<String, Object?>{
        'type': 'echo',
        'connections': _connections,
        'value': message,
      });
    });
    // Leader-handoff-style test: a caller can hand this SharedWorker a
    // MessagePort alongside a 'handoff' command. This proves the
    // SharedWorker side of the proxy design can pick a transferred port out
    // of event.ports (never available on the normalized `messages` stream)
    // and operate it directly.
    controller.rawMessages.listen((event) {
      final data = event.data.dartify();
      if (data is! Map || data['type'] != 'handoff') return;
      final ports = event.ports.toDart;
      if (ports.isEmpty) return;
      final handedOffPort = ports.first..start();
      handedOffPort.onmessage =
          ((MessageEvent inner) {
            handedOffPort.postMessage(
              <String, Object?>{
                'type': 'handoffEcho',
                'value': inner.data.dartify(),
              }.jsify(),
            );
          }).toJS;
    });
    unawaited(
      controller.done.then((_) {
        _connections--;
      }),
    );
  },
);
