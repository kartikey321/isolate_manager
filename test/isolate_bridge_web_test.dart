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
  controller.messages.listen(controller.send);
  controller.initialized();
}

// Same-thread worker that records when onDispose fires.
void Function() _disposeCallback = () {};
void _sameThreadDisposeObserver(dynamic params) {
  final controller = IsolateBridgeController<Object?, Object?>(
    params,
    onDispose: () => _disposeCallback(),
  );
  controller.initialized();
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
      expect((response as Map)['key'], 42);
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
