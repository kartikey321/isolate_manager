import 'dart:async';
import 'dart:typed_data';

import 'package:isolate_manager/isolate_manager.dart';
import 'package:test/test.dart';

void _echoBridgeWorker(dynamic params) {
  final controller = IsolateBridgeController<Object?, Object?>(params);

  controller.messages.listen((message) {
    if (message == 'ping') {
      controller.send('pong');
      return;
    }

    if (message is List) {
      controller.send(message.join(','));
      return;
    }

    if (message is Map && message['bytes'] is Uint8List) {
      final bytes = message['bytes'] as Uint8List;
      controller.send(
        <String, Object?>{
          'length': bytes.length,
          'first': bytes.first,
          'bytes': bytes,
        },
        transferables: [bytes.buffer],
      );
      return;
    }

    controller.send(message);
  });

  controller.initialized();
  scheduleMicrotask(() => controller.send('spontaneous'));
}

void _throwingBridgeWorker(dynamic params) {
  throw StateError('bridge startup failed');
}

void _postInitCrashWorker(dynamic params) {
  IsolateBridgeController<Object?, Object?>(params)
    ..initialized()
    ..messages.listen((_) {});
  scheduleMicrotask(() => throw StateError('post-init crash'));
}

void _sendErrorWorker(dynamic params) {
  final controller = IsolateBridgeController<Object?, Object?>(params)
    ..initialized();
  scheduleMicrotask(
    () => controller.sendError(const IsolateException('worker error')),
  );
}

void _initParamsWorker(dynamic params) {
  final controller = IsolateBridgeController<Object?, Object?>(params)
    ..initialized();
  scheduleMicrotask(() => controller.send(controller.initialParams));
}

void _selfClosingWorker(dynamic params) {
  final controller = IsolateBridgeController<Object?, Object?>(params)
    ..initialized();
  // Close the controller so the IsolateChannel sink closes, the ReceivePort
  // closes, and the isolate exits naturally without a dispose signal from main.
  unawaited(controller.close());
}

void _postInitImmediateCrashWorker(dynamic params) {
  IsolateBridgeController<Object?, Object?>(params)
    ..initialized()
    ..messages.listen((_) {});
  scheduleMicrotask(() => throw StateError('immediate post-init crash'));
}

Future<void> _expectBridgeDoneAfterSpawn(
  Future<IsolateBridge<Object?, Object?>> spawnFuture,
) async {
  final bridge = await spawnFuture.timeout(const Duration(seconds: 2));
  await expectLater(
    bridge.stream,
    emitsDone,
  ).timeout(const Duration(seconds: 2));
}

void main() {
  group('IsolateBridge', () {
    test(
      'receives isolate initiated messages without a compute call',
      () async {
        final bridge = await IsolateBridge.spawn<Object?, Object?>(
          _echoBridgeWorker,
        );

        addTearDown(bridge.close);

        await expectLater(bridge.stream, emits('spontaneous'));
      },
    );

    test(
      'sends messages to a persistent isolate and receives responses',
      () async {
        final bridge = await IsolateBridge.spawn<Object?, Object?>(
          _echoBridgeWorker,
        );

        addTearDown(bridge.close);

        final events = bridge.stream.where((event) => event != 'spontaneous');
        bridge.send('ping');

        await expectLater(events, emits('pong'));
      },
    );

    test('pipes a stream into the isolate', () async {
      final bridge = await IsolateBridge.spawn<Object?, Object?>(
        _echoBridgeWorker,
      );

      addTearDown(bridge.close);

      final events = bridge.stream.where((event) => event != 'spontaneous');
      final subscription = bridge.pipe(
        Stream<Object?>.fromIterable([
          <String>['a', 'b', 'c'],
        ]),
      );
      addTearDown(subscription.cancel);

      await expectLater(events, emits('a,b,c'));
    });

    test('supports native transferables in both directions', () async {
      final bridge = await IsolateBridge.spawn<Object?, Object?>(
        _echoBridgeWorker,
      );

      addTearDown(bridge.close);

      final bytes = Uint8List.fromList(<int>[1, 2, 3, 4]);
      final events = bridge.stream.where((event) => event is Map);

      bridge.send(
        <String, Object?>{
          'bytes': bytes,
        },
        transferables: [bytes.buffer],
      );

      final response = (await events.first)! as Map;
      expect(response['length'], 4);
      expect(response['first'], 1);
      expect(response['bytes'], isA<Uint8List>());
      expect(response['bytes'], <int>[1, 2, 3, 4]);
    });

    test('fails instead of hanging when worker throws before init', () async {
      await expectLater(
        IsolateBridge.spawn<Object?, Object?>(_throwingBridgeWorker),
        throwsA(isA<IsolateException>()),
      );
    });

    test('throws when sending after close', () async {
      final bridge = await IsolateBridge.spawn<Object?, Object?>(
        _echoBridgeWorker,
      );

      await bridge.close();

      expect(
        () => bridge.send('ping'),
        throwsA(isA<IsolateException>()),
      );
    });

    test(
      'surfaces post-init worker crash as a stream error',
      () async {
        final bridge = await IsolateBridge.spawn<Object?, Object?>(
          _postInitCrashWorker,
        );

        addTearDown(bridge.close);

        await expectLater(bridge.stream, emitsError(isA<IsolateException>()));
      },
    );

    test(
      'surfaces worker sendError as a stream error',
      () async {
        final bridge = await IsolateBridge.spawn<Object?, Object?>(
          _sendErrorWorker,
        );

        addTearDown(bridge.close);

        // The controller protocol unwraps IsolateException and adds e.error
        // to the stream, so the emitted error is the raw inner value.
        await expectLater(bridge.stream, emitsError(equals('worker error')));
      },
    );

    test(
      'pipe onError callback fires when send throws after close',
      () async {
        final bridge = await IsolateBridge.spawn<Object?, Object?>(
          _echoBridgeWorker,
        );

        await bridge.close();

        final errors = <Object>[];
        final subscription = bridge.pipe(
          Stream<Object?>.value('ping'),
          onError: (e, _) => errors.add(e),
        );
        addTearDown(subscription.cancel);

        await Future<void>.delayed(Duration.zero);

        expect(errors, [isA<IsolateException>()]);
      },
    );

    test('initialParams are threaded through to the worker', () async {
      const params = <String, Object?>{'key': 42, 'flag': true};
      final bridge = await IsolateBridge.spawn<Object?, Object?>(
        _initParamsWorker,
        initialParams: params,
      );

      addTearDown(bridge.close);

      await expectLater(bridge.stream, emits(params));
    });

    test('stream emits done after close', () async {
      final bridge = await IsolateBridge.spawn<Object?, Object?>(
        _echoBridgeWorker,
      );

      final done = Completer<void>();
      bridge.stream.listen((_) {}, onDone: done.complete);

      await bridge.close();
      await done.future;
    });

    test('close is idempotent', () async {
      final bridge = await IsolateBridge.spawn<Object?, Object?>(
        _echoBridgeWorker,
      );

      // Concurrent and sequential double-close must not throw.
      await Future.wait([bridge.close(), bridge.close()]);
      await bridge.close();
    });

    test('stream emits done when worker exits naturally', () async {
      final bridge = await IsolateBridge.spawn<Object?, Object?>(
        _selfClosingWorker,
      );

      addTearDown(bridge.close);

      await expectLater(bridge.stream, emitsDone);
    });

    test(
      'does not return a dead bridge when worker exits immediately after initialized',
      () async {
        for (var i = 0; i < 100; i++) {
          await _expectBridgeDoneAfterSpawn(
            IsolateBridge.spawn<Object?, Object?>(_selfClosingWorker),
          );
        }
      },
    );

    test(
      'does not miss an immediate post-init crash during spawn handoff',
      () async {
        for (var i = 0; i < 100; i++) {
          final bridge =
              await IsolateBridge.spawn<Object?, Object?>(
                _postInitImmediateCrashWorker,
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
