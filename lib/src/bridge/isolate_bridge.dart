import 'dart:async';
import 'dart:typed_data';

import 'package:isolate_manager/src/base/isolate_contactor.dart';
import 'package:isolate_manager/src/bridge/isolate_bridge_controller.dart';
import 'package:isolate_manager/src/bridge/isolate_bridge_platform.dart'
    if (dart.library.io) 'package:isolate_manager/src/bridge/isolate_bridge_stub.dart';
import 'package:isolate_manager/src/utils/converter.dart';
import 'package:isolate_manager/src/utils/normalize_path.dart';

/// The entry point used by [IsolateBridge.spawn].
///
/// This has the same shape as a custom isolate function. Inside the entry point,
/// create an [IsolateBridgeController] with the provided params.
typedef IsolateBridgeFunction = FutureOr<void> Function(dynamic params);

/// A persistent bidirectional stream bridge between the main isolate and a
/// worker isolate or Web Worker.
///
/// Unlike the task queue API, this API is not request/response based. Messages
/// can be sent in either direction at any time until the bridge is closed.
class IsolateBridge<R, P> {
  IsolateBridge._(this._delegate);

  final IsolateBridgePlatform<R, P> _delegate;

  /// Stream of messages sent by the isolate or worker.
  Stream<R> get stream => _delegate.stream;

  /// Completes when the bridge worker has called
  /// [IsolateBridgeController.initialized]. Always complete by the time
  /// [IsolateBridge.spawn] returns.
  Future<void> get ensureInitialized => _delegate.ensureInitialized;

  /// Sends [message] to the isolate or worker.
  ///
  /// [transferables] can contain [ByteBuffer], [Uint8List], or platform
  /// transferable objects supported by the underlying backend.
  ///
  /// On the web, [transferables] are only honoured when a real JS Worker is in
  /// use (i.e. `workerName` was provided to [spawn]). In the same-thread
  /// fallback the list is silently ignored — the message is passed by reference
  /// and the buffer is not detached from the sender.
  void send(P message, {List<Object>? transferables}) {
    _delegate.send(message, transferables: transferables);
  }

  /// Pipes [input] into the isolate or worker.
  ///
  /// If [onError] is provided it is called for errors on [input] and for
  /// [IsolateException]s thrown by [send] (e.g. when the bridge is already
  /// closed). Without [onError] those errors go to the current error zone.
  StreamSubscription<P> pipe(
    Stream<P> input, {
    List<Object> Function(P message)? transferables,
    void Function(Object error, StackTrace stackTrace)? onError,
  }) {
    return input.listen(
      (message) {
        try {
          send(message, transferables: transferables?.call(message));
        } on Object catch (e, st) {
          if (onError != null) {
            onError(e, st);
          } else {
            Zone.current.handleUncaughtError(e, st);
          }
        }
      },
      onError: onError,
      cancelOnError: false,
    );
  }

  /// Closes this bridge and releases platform resources.
  Future<void> close() => _delegate.close();

  /// Alias for [close].
  Future<void> stop() => close();

  /// Spawns a persistent bridge.
  ///
  /// On VM platforms this spawns a Dart isolate. On web, [workerName] selects a
  /// generated JavaScript worker; when empty, the bridge falls back to the
  /// package's same-thread web controller behavior.
  ///
  /// [workerConverter] is only applied on web when a real JS Worker is used.
  /// On the VM and in the same-thread web fallback it is ignored.
  ///
  /// [enableWasmTransferables] controls whether `transferables` passed to
  /// [send] are forwarded in WASM builds. Disabled by default because most
  /// WASM targets do not yet support structured-clone transfer.
  static Future<IsolateBridge<R, P>> spawn<R, P>(
    IsolateBridgeFunction function, {
    String? workerName,
    Object? initialParams,
    String debugName = 'bridge',
    IsolateConverter<R>? converter,
    IsolateConverter<R>? workerConverter,
    bool enableWasmConverter = true,
    bool enableWasmTransferables = false,
    bool isDebug = false,
  }) async {
    final delegate = await IsolateBridgePlatform.spawn<R, P>(
      function,
      workerName: normalizePath(workerName) ?? '',
      initialParams: initialParams,
      debugName: debugName,
      converter:
          (value) => converterHelper(
            value,
            customConverter: converter,
            enableWasmConverter: enableWasmConverter,
          ),
      workerConverter:
          (value) => converterHelper(
            value,
            customConverter: workerConverter,
            enableWasmConverter: enableWasmConverter,
          ),
      enableWasmTransferables: enableWasmTransferables,
      isDebug: isDebug,
    );

    return IsolateBridge<R, P>._(delegate);
  }
}
