import 'dart:async';
import 'dart:isolate';

import 'package:isolate_manager/src/base/contactor/isolate_contactor_controller.dart';
import 'package:isolate_manager/src/base/contactor/models/isolate_port.dart';
import 'package:isolate_manager/src/base/contactor/models/isolate_state.dart';
import 'package:isolate_manager/src/models/isolate_exceptions.dart';
import 'package:isolate_manager/src/utils/native_transferable_codec.dart';
import 'package:isolate_manager/src/utils/print.dart';
import 'package:stream_channel/isolate_channel.dart';

/// Implementation of the [IsolateContactorController] in `io`.
class IsolateContactorControllerImpl<R, P>
    implements IsolateContactorController<R, P> {
  /// Implementation of the [IsolateContactorController] in `io`.
  IsolateContactorControllerImpl(
    dynamic params, {
    required void Function()? onDispose,
    required R Function(dynamic)? converter,
    // For internal use only
    // ignore: avoid_unused_constructor_parameters
    required R Function(dynamic)? workerConverter,
    required bool debugMode,
  }) : _debugMode = debugMode,
       _onDispose = onDispose,
       _converter = converter,
       _initialParams = params is List ? params.first : null,
       _delegate =
           params is List
               ? IsolateChannel.connectSend(params.last as SendPort)
               : IsolateChannel.connectReceive(params as ReceivePort),
       _mainStreamController = StreamController<R>.broadcast(),
       _isolateStreamController = StreamController<P>.broadcast() {
    _streamSubscription = _delegate.stream.listen(
      _handleEvent,
      onError: _mainStreamController.addError,
      onDone: () => unawaited(_onRemoteClose()),
    );
  }

  final IsolateChannel<dynamic> _delegate;
  final StreamController<R> _mainStreamController;
  final StreamController<P> _isolateStreamController;
  final void Function()? _onDispose;
  final R Function(dynamic)? _converter;
  final dynamic _initialParams;
  late final StreamSubscription<dynamic> _streamSubscription;
  final bool _debugMode;
  bool _isClosed = false;

  @override
  final Completer<void> ensureInitialized = Completer<void>();

  @override
  dynamic get initialParams => _initialParams;

  @override
  Stream<R> get onMessage => _mainStreamController.stream;

  @override
  Stream<P> get onIsolateMessage => _isolateStreamController.stream;

  @override
  void initialized() {
    if (_isClosed) return;
    _delegate.sink.add({IsolatePort.main: IsolateState.initialized});
  }

  @override
  void sendIsolate(P message, {List<Object>? transferables}) {
    if (_isClosed) return;
    final payload = encodeNativeTransferPayload(
      message,
      transferables: transferables,
    );
    _delegate.sink.add({IsolatePort.isolate: payload});
  }

  @override
  void sendIsolateState(IsolateState state) {
    if (_isClosed) return;
    _delegate.sink.add({IsolatePort.isolate: state});
  }

  @override
  void sendResult(R message, {List<Object>? transferables}) {
    if (_isClosed) return;
    final payload = encodeNativeTransferPayload(
      message,
      transferables: transferables,
    );
    _delegate.sink.add({IsolatePort.main: payload});
  }

  @override
  void sendResultError(IsolateException exception) {
    if (_isClosed) return;
    _delegate.sink.add({IsolatePort.main: exception});
  }

  @override
  Future<void> close() async {
    if (_isClosed) return;
    _isClosed = true;
    await Future.wait([
      _mainStreamController.close(),
      _isolateStreamController.close(),
      _streamSubscription.cancel(),
    ]);
    // Close the IsolateChannel sink so the onDone callback fires and closes
    // the underlying ReceivePort. Without this the ReceivePort stays open and
    // the worker isolate never exits on its own.
    await _delegate.sink.close();
  }

  // Called when the remote side closes its IsolateChannel sink (sends
  // _doneToken). Closes our stream controllers so downstream listeners receive
  // done, then closes our own sink to complete the bidirectional handshake so
  // the remote ReceivePort can also close, allowing the isolate to exit.
  Future<void> _onRemoteClose() async {
    if (_isClosed) return;
    _isClosed = true;
    if (!_mainStreamController.isClosed) await _mainStreamController.close();
    if (!_isolateStreamController.isClosed) await _isolateStreamController.close();
    try {
      await _delegate.sink.close();
      // Catch any platform error if the sink was already torn down.
      // ignore: avoid_catches_without_on_clauses
    } catch (_) {}
  }

  Future<void> _handleEvent(dynamic event) async {
    if (event is! Map<IsolatePort, dynamic>) return;

    for (final entry in event.entries) {
      switch (entry.key) {
        case IsolatePort.main:
          _handleMainPort(entry.value);
        case IsolatePort.isolate:
          await _handleIsolatePort(entry.value);
      }
    }
  }

  void _handleMainPort(dynamic value) {
    final decodedValue = decodeNativeTransferPayload(value);

    debugPrinter(
      () => '[Main App] Message received from the Isolate: $decodedValue',
      debug: _debugMode,
    );
    switch (decodedValue) {
      case == IsolateState.initialized:
        if (!ensureInitialized.isCompleted) {
          ensureInitialized.complete();
        }
      case final IsolateException e:
        _mainStreamController.addError(e.error, e.stackTrace);
      default:
        try {
          _mainStreamController.add(
            _converter?.call(decodedValue) ?? decodedValue as R,
          );
          // To catch both Error and Exception
          // ignore: avoid_catches_without_on_clauses
        } catch (e, stack) {
          _mainStreamController.addError(e, stack);
        }
    }
  }

  Future<void> _handleIsolatePort(dynamic value) async {
    final decodedValue = decodeNativeTransferPayload(value);

    debugPrinter(
      () => '[Isolate] Message received from the Main App: $decodedValue',
      debug: _debugMode,
    );
    switch (decodedValue) {
      case == IsolateState.dispose:
        // Guard against a throwing onDispose — if it throws, close() would
        // never be called and any caller waiting for stream-done would hang.
        try {
          _onDispose?.call();
          // Catch both Error and Exception from user-supplied onDispose.
          // ignore: avoid_catches_without_on_clauses
        } catch (_) {}
        await close();
      default:
        try {
          _isolateStreamController.add(decodedValue as P);
          // To catch both Error and Exception
          // ignore: avoid_catches_without_on_clauses
        } catch (e, stack) {
          _isolateStreamController.addError(e, stack);
        }
    }
  }
}
