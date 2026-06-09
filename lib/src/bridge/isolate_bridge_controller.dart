import 'dart:async';

import 'package:isolate_manager/src/isolate_manager.dart';
import 'package:isolate_manager/src/models/isolate_exceptions.dart';

/// Controller used inside an isolate bridge worker.
class IsolateBridgeController<R, P> {
  /// Creates a bridge controller from the params passed to the worker entry
  /// point.
  IsolateBridgeController(dynamic params, {void Function()? onDispose})
    : _delegate = IsolateManagerController<R, P>(
        params,
        onDispose: onDispose,
      );

  final IsolateManagerController<R, P> _delegate;

  /// Initial params passed when spawning the bridge.
  dynamic get initialParams => _delegate.initialParams;

  /// Stream of messages sent by the main isolate.
  Stream<P> get messages => _delegate.onIsolateMessage;

  /// Marks the bridge as ready to receive messages.
  void initialized() => _delegate.initialized();

  /// Sends [message] to the main isolate.
  void send(R message, {List<Object>? transferables}) {
    _delegate.sendResult(message, transferables: transferables);
  }

  /// Sends an error to the main isolate.
  void sendError(IsolateException exception) {
    _delegate.sendResultError(exception);
  }

  /// Closes this side of the bridge.
  Future<void> close() => _delegate.close();
}
