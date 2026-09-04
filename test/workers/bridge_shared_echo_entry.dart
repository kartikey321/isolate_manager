// SharedWorker fixture for IsolateBridge browser tests.

import 'dart:async';

import 'package:isolate_manager/isolate_manager.dart';

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
    unawaited(
      controller.done.then((_) {
        _connections--;
      }),
    );
  },
);
