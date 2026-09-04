// coverage:ignore-file
import 'dart:async';

import 'package:isolate_manager/isolate_manager.dart';

/// VM stub — [isolateBridgeSharedWorkerMain] is only supported on web.
Future<void> isolateBridgeSharedWorkerMain<R, P>(
  Future<void> Function(
    IsolateBridgeSharedWorkerController<R, P> controller,
    Object? initialParams,
  )
  setup, {
  void Function()? onDispose,
}) {
  throw UnsupportedError(
    'isolateBridgeSharedWorkerMain is only available on web. '
    'SharedWorker is a browser API.',
  );
}

/// VM stub — web-only controller.
class IsolateBridgeSharedWorkerController<R, P> {
  IsolateBridgeSharedWorkerController._();

  Object? get initialParams => throw UnsupportedError('web only');
  Stream<P> get messages => throw UnsupportedError('web only');
  Stream<Object?> get rawMessages => throw UnsupportedError('web only');
  Future<void> get done => throw UnsupportedError('web only');
  void initialized() => throw UnsupportedError('web only');
  void send(R message, {List<Object>? transferables}) =>
      throw UnsupportedError('web only');
  void sendError(IsolateException exception) =>
      throw UnsupportedError('web only');
  Future<void> close() => throw UnsupportedError('web only');
}
