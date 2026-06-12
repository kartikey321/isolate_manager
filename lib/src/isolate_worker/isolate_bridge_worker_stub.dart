import 'dart:async';

import 'package:isolate_manager/src/bridge/isolate_bridge_controller.dart';

/// Stub for [isolateBridgeWorkerMain] on non-web-worker platforms.
Future<void> isolateBridgeWorkerMain<R, P>(
  Future<void> Function(
    IsolateBridgeController<R, P> controller,
    Object? initialParams,
  )
  setup, {
  void Function()? onDispose,
}) {
  throw UnsupportedError(
    'isolateBridgeWorkerMain is only available in web workers',
  );
}
