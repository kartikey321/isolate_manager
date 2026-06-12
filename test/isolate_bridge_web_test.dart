@TestOn('browser')
library;

import 'dart:async';

import 'package:isolate_manager/isolate_manager.dart';
import 'package:test/test.dart';

// ---------------------------------------------------------------------------
// Worker-side functions
// ---------------------------------------------------------------------------

// Unused on the web Worker path — the JS worker handles it.
void _unused(dynamic _) {}

// Same-thread echo: runs in the browser's JS event loop (no Worker file).
void _sameThreadEcho(dynamic params) {
  final controller = IsolateBridgeController<Object?, Object?>(params);
  controller
    ..messages.listen(controller.send)
    ..initialized();
}

// Same-thread worker that records when onDispose fires.
void Function() _disposeCallback = () {};
void _sameThreadDisposeObserver(dynamic params) {
  IsolateBridgeController<Object?, Object?>(
    params,
    onDispose: () => _disposeCallback(),
  ).initialized();
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

void main() {
  group('IsolateBridge (web same-thread fallback)', () {
    test('sends and receives messages', () async {
      final bridge = await IsolateBridge.spawn<Object?, Object?>(_sameThreadEcho);
      addTearDown(bridge.close);

      bridge.send('hello');
      await expectLater(bridge.stream, emits('hello'));
    });

    test('stream emits done after close', () async {
      final bridge = await IsolateBridge.spawn<Object?, Object?>(_sameThreadEcho);

      final done = Completer<void>();
      bridge.stream.listen((_) {}, onDone: done.complete);

      await bridge.close();
      // O2 fix: close() must not return until onMessage has emitted done.
      expect(done.isCompleted, isTrue);
    });

    test('close() calls onDispose before returning (O2 fix)', () async {
      var disposeCalled = false;
      _disposeCallback = () => disposeCalled = true;

      final bridge =
          await IsolateBridge.spawn<Object?, Object?>(_sameThreadDisposeObserver);

      await bridge.close();

      expect(disposeCalled, isTrue);
    });

    test('close is idempotent on same-thread path', () async {
      final bridge = await IsolateBridge.spawn<Object?, Object?>(_sameThreadEcho);
      await Future.wait([bridge.close(), bridge.close()]);
      await bridge.close();
    });
  });

  group('IsolateBridge (Dart-compiled web Worker via isolateBridgeWorkerMain)', () {
    // Regression test: IsolateManagerControllerImpl used params.runtimeType ==
    // DedicatedWorkerGlobalScope which was always false in compiled output,
    // causing the controller to never use _IsolateManagerWorkerController and
    // the worker to never send the initialized signal → spawn hung forever.
    test('spawns, echoes, and closes correctly', () async {
      final bridge = await IsolateBridge.spawn<Object?, Object?>(
        _unused,
        workerName: 'workers/bridge_dart_echo',
      ).timeout(const Duration(seconds: 10));

      addTearDown(bridge.close);

      bridge.send('hello from dart worker');
      await expectLater(bridge.stream, emits('hello from dart worker'));
    });

    test('dispose message does not crash the worker (cast-to-P bug fix)', () async {
      final bridge = await IsolateBridge.spawn<Object?, Object?>(
        _unused,
        workerName: 'workers/bridge_dart_echo',
      ).timeout(const Duration(seconds: 10));

      bridge.send('ping');
      await expectLater(bridge.stream, emits('ping'));

      // close() sends a dispose IsolateState message. Before the fix, the
      // worker's onmessage handler passed the Map to stream.cast<P>(), crashing
      // the worker. After the fix it is intercepted and the worker shuts down
      // gracefully.
      final done = Completer<void>();
      bridge.stream.listen((_) {}, onDone: done.complete);
      await bridge.close();
      await done.future.timeout(const Duration(seconds: 5));
    });
  });

  group('IsolateBridge (web Worker)', () {
    test('spawns, sends, and receives messages via a real JS Worker', () async {
      final bridge = await IsolateBridge.spawn<Object?, Object?>(
        _unused,
        workerName: 'workers/bridge_echo',
      );

      addTearDown(bridge.close);

      bridge.send('hello');

      await expectLater(bridge.stream, emits('hello'));
    });

    test('round-trips a map message through the JS Worker', () async {
      final bridge = await IsolateBridge.spawn<Object?, Object?>(
        _unused,
        workerName: 'workers/bridge_echo',
      );

      addTearDown(bridge.close);

      bridge.send(<String, Object?>{'key': 42});

      final response = await bridge.stream.first;
      expect(response, isA<Map<Object?, Object?>>());
      expect((response! as Map<Object?, Object?>)['key'], 42);
    });

    test('initialParams String delivered to JS worker', () async {
      final bridge = await IsolateBridge.spawn<Object?, Object?>(
        _unused,
        workerName: 'workers/bridge_echo_with_params',
        initialParams: 'hello-params',
      );
      addTearDown(bridge.stop);

      expect(await bridge.stream.first, 'hello-params');
    });

    test('initialParams null when not given', () async {
      final bridge = await IsolateBridge.spawn<Object?, Object?>(
        _unused,
        workerName: 'workers/bridge_echo_with_params',
      );
      addTearDown(bridge.stop);

      expect(await bridge.stream.first, isNull);
    });

    test('initialParams Map delivered to JS worker', () async {
      final bridge = await IsolateBridge.spawn<Object?, Object?>(
        _unused,
        workerName: 'workers/bridge_echo_with_params',
        initialParams: <String, Object?>{'key': 42},
      );
      addTearDown(bridge.stop);

      final response = await bridge.stream.first;
      expect(response, isA<Map<Object?, Object?>>());
      expect((response! as Map<Object?, Object?>)['key'], 42);
    });

    test('stream emits done after close', () async {
      final bridge = await IsolateBridge.spawn<Object?, Object?>(
        _unused,
        workerName: 'workers/bridge_echo',
      );

      final done = Completer<void>();
      bridge.stream.listen((_) {}, onDone: done.complete);

      await bridge.close();
      await done.future;
    });

    test('throws when sending after close', () async {
      final bridge = await IsolateBridge.spawn<Object?, Object?>(
        _unused,
        workerName: 'workers/bridge_echo',
      );

      await bridge.close();

      expect(
        () => bridge.send('ping'),
        throwsA(isA<IsolateException>()),
      );
    });

    test('close is idempotent', () async {
      final bridge = await IsolateBridge.spawn<Object?, Object?>(
        _unused,
        workerName: 'workers/bridge_echo',
      );

      await Future.wait([bridge.close(), bridge.close()]);
      await bridge.close();
    });

    test(
      'post-init Worker crash surfaces as a stream error (O1)',
      () async {
        final bridge = await IsolateBridge.spawn<Object?, Object?>(
          _unused,
          workerName: 'workers/bridge_crash_after_init',
        );

        addTearDown(bridge.close);

        // Trigger the crash by sending any message.
        bridge.send('trigger');

        // The uncaught JS exception fires worker.onerror which must surface
        // as an IsolateException on the stream instead of being silently dropped.
        await expectLater(bridge.stream, emitsError(isA<IsolateException>()));
      },
    );

    test(
      'stream emits done after post-init Worker crash',
      () async {
        final bridge = await IsolateBridge.spawn<Object?, Object?>(
          _unused,
          workerName: 'workers/bridge_crash_after_init',
        );

        addTearDown(bridge.close);

        bridge.send('trigger');

        // After the error the stream must also close (shutdown is triggered).
      await expectLater(
        bridge.stream,
        emitsInOrder(<dynamic>[emitsError(anything), emitsDone]),
      );
    },
  );

    test(
      'does not miss an immediate post-init Worker crash during spawn handoff',
      () async {
        for (var i = 0; i < 50; i++) {
          final bridge =
              await IsolateBridge.spawn<Object?, Object?>(
                _unused,
                workerName: 'workers/bridge_exit_after_init',
              ).timeout(const Duration(seconds: 2));

          await expectLater(
            bridge.stream,
            emitsInOrder(<dynamic>[emitsError(isA<IsolateException>()), emitsDone]),
          ).timeout(const Duration(seconds: 2));
        }
      },
    );
  });
}
