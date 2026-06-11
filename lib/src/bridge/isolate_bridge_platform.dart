// Platform implementations are internal and mirror a shared public surface.
// ignore_for_file: public_member_api_docs

import 'dart:async';
import 'dart:js_interop';

import 'package:isolate_manager/src/base/contactor/isolate_contactor_controller/isolate_contactor_controller_web.dart';
import 'package:isolate_manager/src/base/isolate_contactor.dart';
import 'package:isolate_manager/src/bridge/isolate_bridge.dart';
import 'package:isolate_manager/src/utils/converter.dart';
import 'package:web/web.dart';

/// Web implementation of [IsolateBridge].
///
/// Worker path: wraps a JS Worker and owns a broadcast [_streamController].
/// Same-thread path: no worker; stream comes directly from the controller.
class IsolateBridgePlatform<R, P> {
  IsolateBridgePlatform._({
    required IsolateContactorControllerImpl<R, P> controller,
    required bool enableWasmTransferables,
    StreamController<R>? streamController,
  }) : _controller = controller,
       _enableWasmTransferables = enableWasmTransferables,
       _streamController = streamController;

  final IsolateContactorControllerImpl<R, P> _controller;
  final bool _enableWasmTransferables;
  // Non-null only for the JS Worker path — used to surface post-init onerror.
  final StreamController<R>? _streamController;
  StreamSubscription<R>? _forwardSubscription;

  bool _isClosed = false;
  // Cached so every exit signal (onerror, channel onDone, explicit close)
  // awaits the same single cleanup run.
  Future<void>? _shutdownFuture;

  Stream<R> get stream => _streamController?.stream ?? _controller.onMessage;

  Future<void> get ensureInitialized => _controller.ensureInitialized.future;

  // Worker path only. Sets _isClosed synchronously so send() is blocked
  // the instant any exit signal fires.
  Future<void> _shutdown() {
    _isClosed = true;
    return _shutdownFuture ??= _doShutdown();
  }

  Future<void> _doShutdown() async {
    // Cancel forwarding first so the onDone callback does not re-enter.
    await _forwardSubscription?.cancel();
    _forwardSubscription = null;
    final sc = _streamController;
    if (sc != null && !sc.isClosed) await sc.close();
    await _controller.close();
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
    late final IsolateContactorControllerImpl<R, P> controller;

    if (workerName.isNotEmpty) {
      final worker = Worker('$workerName.js'.toJS);
      final streamController = StreamController<R>.broadcast();
      final workerInitError = Completer<void>();
      Future<void>? shutdownFuture;
      var initPhaseComplete = false;

      late final IsolateBridgePlatform<R, P> platform;
      Future<void> shutdown() {
        return shutdownFuture ??= () async {
          platform._isClosed = true;
          await platform._forwardSubscription?.cancel();
          platform._forwardSubscription = null;
          if (!streamController.isClosed) await streamController.close();
          await controller.close();
        }();
      }

      // Race the init handshake against a Worker script error so that a
      // crash during startup fails fast instead of hanging forever (B1 fix).
      worker.onerror = ((ErrorEvent e) {
        if (!workerInitError.isCompleted) {
          workerInitError.completeError(
            IsolateException('Worker failed to start: ${e.message}'),
          );
        }
        if (initPhaseComplete && !streamController.isClosed) {
          streamController.addError(IsolateException('Worker error: ${e.message}'));
        }
        unawaited(shutdown());
      }).toJS;

      controller = IsolateContactorControllerImpl<R, P>(
        worker,
        onDispose: null,
        converter: converter,
        workerConverter: workerConverter,
        debugMode: isDebug,
      );

      platform = IsolateBridgePlatform<R, P>._(
        controller: controller,
        enableWasmTransferables: enableWasmTransferables,
        streamController: streamController,
      )

      // Forward all Worker messages (including errors) to our stream before we
      // await initialization so a post-init immediate crash cannot be missed.
      .._forwardSubscription = controller.onMessage.listen(
        (event) {
          if (!streamController.isClosed) streamController.add(event);
        },
        onError: (Object e, StackTrace st) {
          if (!streamController.isClosed) streamController.addError(e, st);
        },
        onDone: () => unawaited(shutdown()),
      );

      try {
        await Future.any<void>([
          controller.ensureInitialized.future,
          workerInitError.future,
        ]);
      } catch (_) {
        await shutdown();
        rethrow;
      }
      initPhaseComplete = true;

      return platform;
    } else {
      controller = IsolateContactorControllerImpl<R, P>(
        StreamController<dynamic>.broadcast(),
        // Must stay null: both the main-side and worker-side controllers share
        // the same broadcast StreamController, so the dispose signal is
        // delivered to both. A non-null onDispose would fire on the main side
        // too (self-dispose).
        onDispose: null,
        converter: converter,
        workerConverter: workerConverter,
        debugMode: isDebug,
      );

      try {
        await function([initialParams, controller]);
      } catch (error, stackTrace) {
        await controller.close();
        throw IsolateException(error, stackTrace);
      }

      // Fail fast: if the worker returned without calling initialized() we
      // would hang forever on ensureInitialized.future. Surface it now.
      if (!controller.ensureInitialized.isCompleted) {
        await controller.close();
        throw const IsolateException(
          'IsolateBridge same-thread worker returned without calling initialized().',
        );
      }
      await controller.ensureInitialized.future;

      return IsolateBridgePlatform<R, P>._(
        controller: controller,
        enableWasmTransferables: enableWasmTransferables,
      );
    }
  }

  void send(P message, {List<Object>? transferables}) {
    if (_isClosed) {
      throw const IsolateException('The IsolateBridge is already closed.');
    }

    final effectiveTransferables =
        (!_enableWasmTransferables && kIsWasm) ? null : transferables;
    _controller.sendIsolate(message, transferables: effectiveTransferables);
  }

  Future<void> close() async {
    if (_isClosed) return;
    _isClosed = true;

    if (_streamController != null) {
      // Worker path: signal the worker then use _shutdown() for cleanup.
      // _shutdown() is idempotent so concurrent exit signals (onerror,
      // channel onDone) and this explicit close all share one cleanup run.
      _controller.sendIsolateState(IsolateState.dispose);
      await _shutdown();
    } else {
      // Same-thread path: the dispose signal causes _handleIsolatePort to
      // call controller.close() asynchronously. We wait for onMessage to
      // emit done (proof that close() completed) rather than calling
      // close() ourselves, which would race with the dispose handler's
      // async close and could cancel the stream subscription before the
      // handler finishes.
      //
      // Set up the listener BEFORE sending dispose so we never miss the
      // done event even if the broadcast SC delivers synchronously.
      final doneCompleter = Completer<void>();
      final sub = _controller.onMessage.listen(
        (_) {},
        onDone: () {
          if (!doneCompleter.isCompleted) doneCompleter.complete();
        },
        // Swallow errors — callers subscribe to stream separately.
        onError: (Object e, StackTrace s) {},
        cancelOnError: false,
      );
      _controller.sendIsolateState(IsolateState.dispose);
      await doneCompleter.future;
      await sub.cancel();
    }
  }
}
