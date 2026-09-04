import 'dart:async';
import 'dart:js_interop';

import 'package:isolate_manager/src/base/contactor/isolate_contactor_controller/isolate_contactor_controller_web.dart';
import 'package:isolate_manager/src/base/isolate_contactor.dart';
import 'package:isolate_manager/src/models/isolate_types.dart';
import 'package:isolate_manager/src/utils/check_subtype.dart';
import 'package:isolate_manager/src/utils/extract_array_buffers.dart';
import 'package:isolate_manager/src/utils/print.dart';
import 'package:web/web.dart';

/// Implementation using [Worker] or [MessagePort] as the communication channel.
class IsolateContactorControllerImplWorker<R, P>
    implements IsolateContactorControllerImpl<R, P> {
  /// Implementation of the [IsolateContactorController] in `web` with `Worker`
  /// or a SharedWorker [MessagePort].
  IsolateContactorControllerImplWorker(
    dynamic params, {
    required void Function()? onDispose,
    required R Function(dynamic) workerConverter,
    required bool debugMode,
  }) : _debugMode = debugMode,
       _workerConverter = workerConverter,
       _onDispose = onDispose,
       _delegate =
           params is List
               ? (params.last as IsolateContactorControllerImpl).controller
               : params as Worker,
       _initialParams = params is List ? params.first : null,
       _mainStreamController = StreamController<R>.broadcast() {
    _setOnMessage(_handleMessage.toJS);
    if ((_delegate as JSObject).isA<MessagePort>()) {
      (_delegate as MessagePort).start();
    }
  }

  final Object _delegate;
  final void Function()? _onDispose;
  final IsolateConverter<R> _workerConverter;
  final dynamic _initialParams;
  final StreamController<R> _mainStreamController;
  final bool _debugMode;

  @override
  final Completer<void> ensureInitialized = Completer<void>();

  @override
  Object get controller => _delegate;

  @override
  dynamic get initialParams => _initialParams;

  @override
  Stream<R> get onMessage => _mainStreamController.stream;

  @override
  void sendIsolate(P message, {List<Object>? transferables}) {
    final jsMessage =
        message is ImType ? message.unwrap.jsify() : message.jsify();

    if (transferables != null && transferables.isNotEmpty) {
      final jsTransferables = extractArrayBuffers(transferables);
      _postMessage(jsMessage, jsTransferables);
    } else {
      _postMessage(jsMessage);
    }
  }

  @override
  void sendIsolateState(IsolateState state) {
    _postMessage(state.toMap().jsify());
  }

  // TODO(lamnhan066): Find a way to test these methods because it only used by the compiled JS Worker.
  // coverage:ignore-start
  @override
  Stream<P> get onIsolateMessage =>
      throw UnimplementedError('onIsolateMessage is not implemented');

  @override
  Future<void> initialized() =>
      throw UnimplementedError('initialized method is not implemented');

  @override
  void sendResult(R message, {List<Object>? transferables}) =>
      throw UnimplementedError('sendResult is not implemented');

  @override
  void sendResultError(IsolateException exception) =>
      throw UnimplementedError('sendResultError is not implemented');
  // coverage:ignore-end

  @override
  Future<void> close() async {
    final delegate = _delegate as JSObject;
    if (delegate.isA<Worker>()) {
      (delegate as Worker).terminate();
    } else if (delegate.isA<MessagePort>()) {
      (delegate as MessagePort).close();
    }
    await _mainStreamController.close();
  }

  void _setOnMessage(EventHandler handler) {
    final delegate = _delegate as JSObject;
    if (delegate.isA<Worker>()) {
      (delegate as Worker).onmessage = handler;
    } else if (delegate.isA<MessagePort>()) {
      (delegate as MessagePort).onmessage = handler;
    } else {
      throw UnsupportedError(
        'Unsupported web contactor delegate: ${delegate.runtimeType}',
      );
    }
  }

  void _postMessage(JSAny? message, [JSObject? transfer]) {
    final delegate = _delegate as JSObject;
    if (delegate.isA<Worker>()) {
      if (transfer == null) {
        (delegate as Worker).postMessage(message);
      } else {
        (delegate as Worker).postMessage(message, transfer);
      }
    } else if (delegate.isA<MessagePort>()) {
      if (transfer == null) {
        (delegate as MessagePort).postMessage(message);
      } else {
        (delegate as MessagePort).postMessage(message, transfer);
      }
    } else {
      throw UnsupportedError(
        'Unsupported web contactor delegate: ${delegate.runtimeType}',
      );
    }
  }

  /// Centralizes the event processing for the incoming worker messages.
  // Can't return `Future<void>` because of the `onmessage` signature.
  void _handleMessage(MessageEvent event) {
    debugPrinter(
      () => '[Main App] Message received from the Web Worker: ${event.data}',
      debug: _debugMode,
    );

    try {
      final data = event.data.dartify() as Map?;

      if (data == null) return;

      if (data['type'] == 'data') {
        var result = data['value'];
        if (isImTypeSubtype<R>()) {
          result = ImType.wrap(result as Object);
        }
        _mainStreamController.add(_workerConverter(result));
        return;
      }

      if (IsolateState.initialized.isValidMap(data)) {
        if (!ensureInitialized.isCompleted) ensureInitialized.complete();
        return;
      }

      if (IsolateState.dispose.isValidMap(data)) {
        _onDispose?.call();
        unawaited(close());
        return;
      }

      if (IsolateException.isValidMap(data)) {
        final e = IsolateException.fromMap(data);
        _mainStreamController.addError(e, e.stackTrace);
        return;
      }

      _mainStreamController.addError(
        IsolateException('Unhandled $data from the Isolate'),
      );
      // To catch both Error and Exception
      // ignore: avoid_catches_without_on_clauses
    } catch (e, stackTrace) {
      _mainStreamController.addError(
        IsolateException(e, stackTrace),
        stackTrace,
      );
    }
  }
}
