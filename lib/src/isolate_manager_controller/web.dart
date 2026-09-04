import 'dart:async';
import 'dart:js_interop';

import 'package:isolate_manager/isolate_manager.dart';
import 'package:isolate_manager/src/base/isolate_contactor.dart';
import 'package:isolate_manager/src/models/initial_params_mixin.dart';
import 'package:isolate_manager/src/utils/check_subtype.dart';
import 'package:isolate_manager/src/utils/converter.dart' show kIsWasm;
import 'package:isolate_manager/src/utils/extract_array_buffers.dart';
import 'package:isolate_manager/src/utils/normalize_worker_message.dart';
import 'package:web/web.dart';

/// This method only use to create a custom isolate.
class IsolateManagerControllerImpl<R, P>
    with InitialParamsMixin
    implements IsolateManagerController<R, P> {
  /// This method only use to create a custom isolate.
  ///
  /// The [params] is a default parameter of a custom isolate function.
  /// `onDispose` will be called when the controller is disposed.
  IsolateManagerControllerImpl(
    dynamic params, {
    void Function()? onDispose,
    Object? initialParams,
    bool captureInitialMessageAsParams = false,
  }) : _delegate =
           // Use JS instanceof (via instanceOfString) rather than Dart `is`
           // checks. Extension-type `is` checks erase to their representation
           // type at runtime and are unreliable across DDC and dart2js.
           // instanceOfString is the pattern used by sqlite3_web and other
           // production packages for exactly this check.
           // ignore: invalid_runtime_check_with_js_interop_types
           params is JSObject &&
                   params.instanceOfString('DedicatedWorkerGlobalScope')
               ? _IsolateManagerWorkerController<R, P>(
                 params as DedicatedWorkerGlobalScope,
                 onDispose: onDispose,
                 initialParams: initialParams,
                 captureInitialMessageAsParams: captureInitialMessageAsParams,
               )
               : IsolateContactorController<R, P>(params, onDispose: onDispose);

  /// Delegation of IsolateContactor.
  final IsolateContactorController<R, P> _delegate;

  /// Mark the isolate as initialized.
  ///
  /// This method is automatically applied when using `IsolateManagerFunction.customFunction`
  /// and `IsolateManagerFunction.workerFunction`.
  @override
  void initialized() => _delegate.initialized();

  /// Close this `IsolateManagerController`.
  @override
  Future<void> close() => _delegate.close();

  /// Get initial parameters when you create the IsolateManager.
  @override
  dynamic get initialParams => _delegate.initialParams;

  /// This parameter is only used for Isolate. Use to listen for values from the main application.
  @override
  Stream<P> get onIsolateMessage => _delegate.onIsolateMessage;

  /// Send values from Isolate to the main application (to `onMessage`).
  @override
  void sendResult(R result, {List<Object>? transferables}) =>
      _delegate.sendResult(result, transferables: transferables);

  /// Send the `Exception` to the main app.
  @override
  void sendResultError(IsolateException exception) =>
      _delegate.sendResultError(exception);
}

// TODO(lamnhan066): Find a way to test these methods because it only used by the compiled JS Worker.
// coverage:ignore-start
class _IsolateManagerWorkerController<R, P>
    implements IsolateContactorController<R, P> {
  _IsolateManagerWorkerController(
    this.self, {
    this.onDispose,
    Object? initialParams,
    bool captureInitialMessageAsParams = false,
  }) : _initialParams = initialParams,
       _captureInitialMessageAsParams = captureInitialMessageAsParams {
    self.onmessage =
        (MessageEvent event) {
          try {
            final normalized = normalizeWorkerMessage(event.data.dartify());
            // Filter IsolateState control messages so they are never cast to P.
            // The dispose signal is the only one main sends to a worker; any
            // future IsolateState variant would likewise be a control message,
            // not application data.
            if (normalized is Map && normalized['type'] == r'$IsolateState') {
              if (normalized['value'] == 'dispose') {
                onDispose?.call();
                self.close();
              }
              return;
            }
            if (_captureInitialMessageAsParams && !_didCaptureInitialMessage) {
              _initialParams = normalized;
              _didCaptureInitialMessage = true;
              return;
            }
            dynamic result = normalized;
            if (isImTypeSubtype<P>()) {
              result = ImType.wrap(result as Object);
            }
            _streamController.sink.add(result);
          } catch (error, stackTrace) {
            print(
              '[IsolateManagerWorkerController] onmessage error '
              'data=${event.data} error=$error stack=$stackTrace',
            );
            rethrow;
          }
        }.toJS;
  }
  final DedicatedWorkerGlobalScope self;
  final void Function()? onDispose;
  Object? _initialParams;
  final bool _captureInitialMessageAsParams;
  bool _didCaptureInitialMessage = false;
  final _streamController = StreamController<dynamic>.broadcast();

  @override
  Stream<P> get onIsolateMessage => _streamController.stream.cast<P>();

  @override
  Object? get initialParams => _initialParams;

  /// Send result to the main app
  @override
  void sendResult(R m, {List<Object>? transferables}) {
    final value = m is ImType ? m.unwrap : m;
    final payload = <String, Object?>{'type': 'data', 'value': value}.jsify();

    if (transferables != null && transferables.isNotEmpty) {
      // Extract ArrayBuffers from transferables for zero-copy transfer
      final jsTransferables = extractArrayBuffers(transferables);
      self.postMessage(payload, jsTransferables);
    } else {
      self.postMessage(payload);
    }
  }

  /// Send error to the main app
  @override
  void sendResultError(IsolateException exception) {
    self.postMessage(exception.toMap().jsify());
  }

  /// Mark the Worker as initialized
  @override
  void initialized() {
    self.postMessage(IsolateState.initialized.toMap().jsify());
  }

  /// Close this `IsolateManagerWorkerController`.
  @override
  Future<void> close() async {
    self.close();
  }

  @override
  Completer<void> get ensureInitialized => throw UnimplementedError();

  @override
  Stream<R> get onMessage => throw UnimplementedError();

  @override
  void sendIsolate(dynamic message, {List<Object>? transferables}) =>
      throw UnimplementedError();

  @override
  void sendIsolateState(IsolateState state) => throw UnimplementedError();
}

// coverage:ignore-end

/// Worker-side controller that communicates through a [MessagePort].
///
/// Used by [isolateBridgeSharedWorkerMain]: each connecting tab receives its
/// own [MessagePort] from the SharedWorker `onconnect` event, and each port
/// gets one independent controller instance backed by that port.
///
/// The API is identical to [_IsolateManagerWorkerController] — `postMessage` /
/// `onmessage` / `close()` exist on both [DedicatedWorkerGlobalScope] and
/// [MessagePort].
class IsolateManagerMessagePortController<R, P>
    implements IsolateContactorController<R, P> {
  // coverage:ignore-start
  IsolateManagerMessagePortController(
    this.port, {
    this.onDispose,
    Object? initialParams,
    bool captureInitialMessageAsParams = false,
    // When false (default), transferables are silently dropped on WASM builds
    // because most dart2wasm targets do not yet support structured-clone
    // transfer. Set to true only if your WASM target is known to support it.
    this.enableWasmTransferables = false,
  }) : _initialParams = initialParams,

       _captureInitialMessageAsParams = captureInitialMessageAsParams {
    port.onmessage =
        (MessageEvent event) {
          try {
            final normalized = normalizeWorkerMessage(event.data.dartify());
            if (normalized is Map && normalized['type'] == r'$IsolateState') {
              if (normalized['value'] == 'dispose') {
                onDispose?.call();
                // A SharedWorker stays alive after an individual tab leaves.
                // Closing only the JS port leaks this controller's Dart stream
                // (and any listeners held by application code) forever.
                unawaited(close());
              }
              return;
            }
            if (_captureInitialMessageAsParams && !_didCaptureInitialMessage) {
              _initialParams = normalized;
              _didCaptureInitialMessage = true;
              return;
            }
            dynamic result = normalized;
            if (isImTypeSubtype<P>()) {
              result = ImType.wrap(result as Object);
            }
            _streamController.sink.add(result);
          } catch (error, stackTrace) {
            print(
              '[IsolateManagerMessagePortController] onmessage error '
              'data=${event.data} error=$error stack=$stackTrace',
            );
            rethrow;
          }
        }.toJS;
  }

  final MessagePort port;
  final void Function()? onDispose;

  /// Controls whether [transferables] passed to [sendResult] are forwarded on
  /// WASM builds. Disabled by default.
  final bool enableWasmTransferables;
  Object? _initialParams;

  final bool _captureInitialMessageAsParams;
  bool _didCaptureInitialMessage = false;
  final _streamController = StreamController<dynamic>.broadcast();
  final Completer<void> _closed = Completer<void>();

  @override
  Stream<P> get onIsolateMessage => _streamController.stream.cast<P>();

  /// Completes once this client port has been disposed or closed.
  Future<void> get done => _closed.future;

  @override
  Object? get initialParams => _initialParams;

  @override
  void sendResult(R m, {List<Object>? transferables}) {
    final value = m is ImType ? m.unwrap : m;
    final payload = <String, Object?>{'type': 'data', 'value': value}.jsify();

    // Drop transferables on WASM unless explicitly opted in — matches the
    // main-side guard in IsolateBridgePlatform.send().
    final effectiveTransferables =
        (!enableWasmTransferables && kIsWasm) ? null : transferables;

    if (effectiveTransferables != null && effectiveTransferables.isNotEmpty) {
      final jsTransferables = extractArrayBuffers(effectiveTransferables);
      port.postMessage(payload, jsTransferables);
    } else {
      port.postMessage(payload);
    }
  }

  @override
  void sendResultError(IsolateException exception) {
    port.postMessage(exception.toMap().jsify());
  }

  @override
  void initialized() {
    port.postMessage(IsolateState.initialized.toMap().jsify());
  }

  @override
  Future<void> close() async {
    port.close();
    await _streamController.close();
    if (!_closed.isCompleted) _closed.complete();
  }

  @override
  Completer<void> get ensureInitialized => throw UnimplementedError();

  @override
  Stream<R> get onMessage => throw UnimplementedError();

  @override
  void sendIsolate(dynamic message, {List<Object>? transferables}) =>
      throw UnimplementedError();

  @override
  void sendIsolateState(IsolateState state) => throw UnimplementedError();
  // coverage:ignore-end
}
