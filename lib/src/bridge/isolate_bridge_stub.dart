// Platform implementations are internal and mirror a shared public surface.
// ignore_for_file: public_member_api_docs

import 'dart:async';
import 'dart:isolate';

import 'package:isolate_manager/src/base/contactor/isolate_contactor_controller/isolate_contactor_controller_stub.dart';
import 'package:isolate_manager/src/base/isolate_contactor.dart';
import 'package:isolate_manager/src/bridge/isolate_bridge.dart';

/// VM implementation of [IsolateBridge].
class IsolateBridgePlatform<R, P> {
  IsolateBridgePlatform._({
    required ReceivePort receivePort,
    required ReceivePort errorPort,
    required ReceivePort exitPort,
    required Isolate isolate,
    required IsolateContactorControllerImpl<R, P> controller,
    required StreamController<R> streamController,
    required Completer<void> workerExitCompleter,
  }) : _receivePort = receivePort,
       _errorPort = errorPort,
       _exitPort = exitPort,
       _isolate = isolate,
       _controller = controller,
       _streamController = streamController,
       _workerExitCompleter = workerExitCompleter;

  final ReceivePort _receivePort;
  final ReceivePort _errorPort;
  final ReceivePort _exitPort;
  final Isolate _isolate;
  final IsolateContactorControllerImpl<R, P> _controller;
  final StreamController<R> _streamController;
  final Completer<void> _workerExitCompleter;

  bool _isClosed = false;
  // Cached so every signal path awaits the same single cleanup run.
  Future<void>? _shutdownFuture;

  Stream<R> get stream => _streamController.stream;

  Future<void> get ensureInitialized => _controller.ensureInitialized.future;

  // Single cleanup entry-point. Sets _isClosed synchronously so that send()
  // and close() are blocked the moment any exit signal fires.
  Future<void> _shutdown() {
    _isClosed = true;
    return _shutdownFuture ??= _doShutdown();
  }

  Future<void> _doShutdown() async {
    _errorPort.close();
    _exitPort.close();
    await _controller.close();
    _receivePort.close();
    if (!_streamController.isClosed) await _streamController.close();
    _isolate.kill();
  }

  static Future<IsolateBridgePlatform<R, P>> spawn<R, P>(
    IsolateBridgeFunction function, {
    required String workerName,
    required Object? initialParams,
    required String debugName,
    required IsolateConverter<R> converter,
    required IsolateConverter<R> workerConverter,
    required bool enableWasmTransferables,
    required bool isDebug,
  }) async {
    final receivePort = ReceivePort();
    final errorPort = ReceivePort();
    final exitPort = ReceivePort();
    final controller = IsolateContactorControllerImpl<R, P>(
      receivePort,
      onDispose: null,
      converter: converter,
      workerConverter: workerConverter,
      debugMode: isDebug,
    );

    final streamController = StreamController<R>.broadcast();
    final workerExitCompleter = Completer<void>();
    final initFailedCompleter = Completer<void>();
    var initPhaseComplete = false;
    Isolate? isolate;
    Future<void>? shutdownFuture;

    Future<void> shutdown() {
      return shutdownFuture ??= () async {
        errorPort.close();
        exitPort.close();
        await controller.close();
        receivePort.close();
        if (!streamController.isClosed) await streamController.close();
        isolate?.kill();
      }();
    }

    // Forward all worker messages to the public stream for the bridge lifetime.
    controller.onMessage.listen(
      (event) {
        if (!streamController.isClosed) streamController.add(event);
      },
      onError: (Object e, StackTrace st) {
        if (!streamController.isClosed) streamController.addError(e, st);
      },
      onDone: () {
        unawaited(shutdown());
      },
    );

    // Wire errorPort for init-phase failure detection and post-init crash
    // propagation. Keeping this port open after spawn (rather than closing it)
    // is the fix for B2: unhandled isolate exceptions surface as stream errors.
    errorPort.listen((error) {
      final ex = _spawnError(error);
      if (!initPhaseComplete) {
        if (!initFailedCompleter.isCompleted) {
          initFailedCompleter.completeError(ex);
        }
        unawaited(shutdown());
      } else {
        if (!streamController.isClosed) streamController.addError(ex);
        unawaited(shutdown());
      }
    });

    // Wire exitPort for init-phase premature-exit detection and post-init
    // graceful-shutdown signalling.
    exitPort.listen((_) {
      if (!initPhaseComplete) {
        if (!initFailedCompleter.isCompleted) {
          initFailedCompleter.completeError(
            const IsolateException(
              'The IsolateBridge worker exited before initialization.',
            ),
          );
        }
        if (!workerExitCompleter.isCompleted) workerExitCompleter.complete();
        unawaited(shutdown());
      } else {
        if (!workerExitCompleter.isCompleted) workerExitCompleter.complete();
        unawaited(shutdown());
      }
    });

    try {
      isolate = await Isolate.spawn(
        function,
        <Object?>[initialParams, receivePort.sendPort],
        debugName: debugName,
        onError: errorPort.sendPort,
        onExit: exitPort.sendPort,
      );

      await Future.any<void>([
        controller.ensureInitialized.future,
        initFailedCompleter.future,
      ]);
    } catch (_) {
      initPhaseComplete = true;
      await shutdown();
      rethrow;
    }

    initPhaseComplete = true;

    return IsolateBridgePlatform<R, P>._(
      receivePort: receivePort,
      errorPort: errorPort,
      exitPort: exitPort,
      isolate: isolate,
      controller: controller,
      streamController: streamController,
      workerExitCompleter: workerExitCompleter,
    );
  }

  void send(P message, {List<Object>? transferables}) {
    if (_isClosed) {
      throw const IsolateException('The IsolateBridge is already closed.');
    }

    _controller.sendIsolate(message, transferables: transferables);
  }

  Future<void> close() async {
    if (_isClosed) return;
    // Set immediately so send() is blocked from this point forward and
    // a concurrent close() call returns early.
    _isClosed = true;

    // Ask the worker to shut down gracefully.
    _controller.sendIsolateState(IsolateState.dispose);

    // Wait up to 3 seconds for the worker to acknowledge exit via exitPort
    // before doing hard cleanup. This is the fix for B3: the original code
    // killed the isolate immediately, racing with the worker's onDispose.
    await Future.any<void>([
      _workerExitCompleter.future,
      Future<void>.delayed(const Duration(seconds: 3)),
    ]);

    await _shutdown();
  }

  static IsolateException _spawnError(Object? error) {
    if (error is List && error.isNotEmpty) {
      final exception = error.first;
      final stackTrace =
          error.length > 1
              ? StackTrace.fromString('${error[1]}')
              : StackTrace.empty;
      final safeException = exception is Object ? exception : '$exception';
      return IsolateException(safeException, stackTrace);
    }

    return IsolateException(error ?? 'Unknown isolate error');
  }
}
