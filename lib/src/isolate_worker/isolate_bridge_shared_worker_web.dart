// coverage:ignore-file
// Worker-side entry point for a SharedWorker.
//
// Unlike a dedicated Worker, a SharedWorker receives one [MessagePort] per
// connecting tab via the `onconnect` event. This helper wires the global
// `onconnect` callback and calls [setup] once for every new port.
//
// Usage in a shared worker entry point:
// ```dart
// import 'package:isolate_manager/isolate_manager.dart';
//
// Future<void> main() {
//   return isolateBridgeSharedWorkerMain<String, String>((controller, params) async {
//     controller.initialized(); // unblocks IsolateBridge.spawn on the main side
//     controller.messages.listen((msg) => controller.send('echo:$msg'));
//   });
// }
// ```
//
// **Important**: [setup] is called once per connecting tab, not once globally.
// If you need shared global state across tabs (e.g. a single WorkerCore),
// allocate it outside [setup] — typically before calling
// [isolateBridgeSharedWorkerMain] — and access it by closure.

import 'dart:async';
import 'dart:js_interop';

import 'package:isolate_manager/isolate_manager.dart';
import 'package:isolate_manager/src/isolate_manager_controller/web.dart'
    show IsolateManagerMessagePortController;
import 'package:web/web.dart';

@JS('self')
external SharedWorkerGlobalScope get _self;

/// Boots an [IsolateBridgeSharedWorkerController] for each tab that connects
/// to this SharedWorker, and passes the first message received on that port as
/// `initialParams`.
///
/// The function mirrors [isolateBridgeWorkerMain] but operates on a
/// `SharedWorkerGlobalScope` instead of a `DedicatedWorkerGlobalScope`.
/// Each call to [setup] corresponds to exactly one tab connection.
///
/// [onDispose] is called when the tab sends a dispose signal (i.e. the
/// [IsolateBridge] on that tab is closed).
Future<void> isolateBridgeSharedWorkerMain<R, P>(
  Future<void> Function(
    IsolateBridgeSharedWorkerController<R, P> controller,
    Object? initialParams,
  )
  setup, {
  void Function()? onDispose,
}) async {
  _self.onconnect =
      ((MessageEvent connectEvent) {
        final port = connectEvent.ports.toDart.first..start();

        _handleConnection<R, P>(port, setup, onDispose: onDispose);
      }).toJS;

  // Keep the shared worker alive indefinitely — the onconnect callback
  // above handles the per-tab lifetime.
}

/// Wires [port] up to a fresh controller and calls [setup].
///
/// The first message on the port is treated as `initialParams` (matching the
/// protocol of [isolateBridgeWorkerMain]).
void _handleConnection<R, P>(
  MessagePort port,
  Future<void> Function(
    IsolateBridgeSharedWorkerController<R, P>,
    Object?,
  )
  setup, {
  void Function()? onDispose,
}) {
  final initialParamsCompleter = Completer<Object?>();
  var firstMessage = true;

  // Capture only the very first message as initialParams.
  port.onmessage =
      ((MessageEvent event) {
        if (firstMessage) {
          firstMessage = false;
          initialParamsCompleter.complete(event.data.dartify());
        }
      }).toJS;

  unawaited(
    initialParamsCompleter.future.then((initialParams) {
      final portController = IsolateManagerMessagePortController<R, P>(
        port,
        onDispose: onDispose,
        initialParams: initialParams,
      );
      final controller = IsolateBridgeSharedWorkerController<R, P>._(
        portController,
        initialParams,
      );
      unawaited(
        setup(controller, initialParams).catchError((Object e, StackTrace st) {
          portController.sendResultError(IsolateException(e, st));
          unawaited(portController.close());
        }),
      );
    }),
  );
}

/// Controller exposed to the [setup] callback in [isolateBridgeSharedWorkerMain].
///
/// Provides the same surface as [IsolateBridgeController] but is backed by a
/// [MessagePort] (one per tab) instead of a [DedicatedWorkerGlobalScope].
class IsolateBridgeSharedWorkerController<R, P> {
  IsolateBridgeSharedWorkerController._(
    this._delegate,
    this._initialParams,
  );

  final IsolateManagerMessagePortController<R, P> _delegate;
  final Object? _initialParams;

  /// Initial params passed from the main-side [IsolateBridge.spawn] call.
  Object? get initialParams => _initialParams;

  /// Stream of messages sent by the main isolate (this tab's port).
  Stream<P> get messages => _delegate.onIsolateMessage;

  /// Completes when this tab disconnects from the SharedWorker.
  ///
  /// A shared service should use this to drop tab-scoped subscriptions; it
  /// must not tear down global state until its own client registry is empty.
  Future<void> get done => _delegate.done;

  /// Marks the bridge as ready to receive messages.
  ///
  /// Must be called inside [setup] to unblock [IsolateBridge.spawn] on the
  /// connecting tab's side.
  void initialized() => _delegate.initialized();

  /// Sends [message] to the main isolate (this tab only).
  void send(R message, {List<Object>? transferables}) =>
      _delegate.sendResult(message, transferables: transferables);

  /// Sends an error to the main isolate (this tab only).
  void sendError(IsolateException exception) =>
      _delegate.sendResultError(exception);

  /// Closes this side of the port.
  Future<void> close() => _delegate.close();
}
