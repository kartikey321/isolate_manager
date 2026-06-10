// Platform implementations are internal and mirror a shared public surface.
// ignore_for_file: public_member_api_docs

import 'dart:async';
import 'dart:js_interop';

import 'package:isolate_manager/src/base/contactor/isolate_contactor_controller/isolate_contactor_controller_web.dart';
import 'package:isolate_manager/src/base/isolate_contactor.dart';
import 'package:isolate_manager/src/bridge/isolate_bridge.dart';
import 'package:isolate_manager/src/utils/converter.dart';
import 'package:web/web.dart';

/// Same-thread web fallback implementation.
class IsolateBridgePlatform<R, P> {
  IsolateBridgePlatform._({
    required IsolateContactorControllerImpl<R, P> controller,
    required bool enableWasmTransferables,
  }) : _controller = controller,
       _enableWasmTransferables = enableWasmTransferables;

  final IsolateContactorControllerImpl<R, P> _controller;
  final bool _enableWasmTransferables;
  bool _isClosed = false;

  Stream<R> get stream => _controller.onMessage;

  Future<void> get ensureInitialized => _controller.ensureInitialized.future;

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
    final IsolateContactorControllerImpl<R, P> controller;

    if (workerName.isNotEmpty) {
      final worker = Worker('$workerName.js'.toJS);
      // Race the init handshake against a Worker script error so that a
      // crash during startup fails fast instead of hanging forever (B1 fix).
      final workerInitError = Completer<void>();
      worker.onerror = ((ErrorEvent e) {
        if (!workerInitError.isCompleted) {
          workerInitError.completeError(
            IsolateException('Worker failed to start: ${e.message}'),
          );
        }
      }).toJS;

      controller = IsolateContactorControllerImpl<R, P>(
        worker,
        onDispose: null,
        converter: converter,
        workerConverter: workerConverter,
        debugMode: isDebug,
      );

      try {
        await Future.any<void>([
          controller.ensureInitialized.future,
          workerInitError.future,
        ]);
      } catch (_) {
        await controller.close();
        rethrow;
      }
      // Silence any onerror that fires after init completes successfully.
      unawaited(workerInitError.future.catchError((_) {}));
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

      await controller.ensureInitialized.future;
    }

    return IsolateBridgePlatform<R, P>._(
      controller: controller,
      enableWasmTransferables: enableWasmTransferables,
    );
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
    _controller.sendIsolateState(IsolateState.dispose);
    await _controller.close();
  }
}
