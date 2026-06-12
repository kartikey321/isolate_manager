import 'dart:async';

import 'package:isolate_manager/src/isolate_manager.dart';
import 'package:isolate_manager/src/models/isolate_exceptions.dart';

/// Controller used inside an isolate bridge worker.
class IsolateBridgeController<R, P> {
  /// Creates a bridge controller from the params passed to the worker entry
  /// point.
  IsolateBridgeController(
    dynamic params, {
    void Function()? onDispose,
    Object? initialParams = _unsetInitialParams,
  }) : _delegate = IsolateManagerController<R, P>(
         params,
         onDispose: onDispose,
         initialParams:
             identical(initialParams, _unsetInitialParams)
                 ? null
                 : initialParams,
         captureInitialMessageAsParams: identical(
           initialParams,
           _unsetInitialParams,
         ),
       );

  final IsolateManagerController<R, P> _delegate;

  static const Object _unsetInitialParams = Object();

  /// Initial params passed when spawning the bridge.
  dynamic get initialParams => _delegate.initialParams;

  /// Stream of messages sent by the main isolate.
  Stream<P> get messages => _delegate.onIsolateMessage;

  /// Marks the bridge as ready to receive messages.
  void initialized() => _delegate.initialized();

  /// Sends [message] to the main isolate.
  ///
  /// [transferables] are only honoured on web when a real JS Worker is in use.
  /// In the same-thread web fallback they are silently ignored and the buffer
  /// is not detached.
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
