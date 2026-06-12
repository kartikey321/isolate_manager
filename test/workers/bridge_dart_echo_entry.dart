// Dart-compiled web worker entry point for IsolateBridge browser tests.
// Exercises the isolateBridgeWorkerMain bootstrap path end-to-end.
// Compile: dart compile js -O1 -o test/workers/bridge_dart_echo.js test/workers/bridge_dart_echo_entry.dart

import 'package:isolate_manager/isolate_manager.dart';

Future<void> main() => isolateBridgeWorkerMain<Object?, Object?>(
      (controller, initialParams) async {
        controller.initialized();
        controller.messages.listen(controller.send);
      },
    );
