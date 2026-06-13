@TestOn('browser')
library;

import 'dart:async';

import 'package:isolate_manager/isolate_manager.dart';
import 'package:test/test.dart';

// ---------------------------------------------------------------------------
// Same-thread worker entry points
// ---------------------------------------------------------------------------

// Echo worker: sends back what it receives with requestId and terminal flag.
void _echoWorker(dynamic params) {
  final controller =
      IsolateBridgeController<Map<String, Object?>, Map<String, Object?>>(params);
  controller.messages.listen((message) {
    controller.send(<String, Object?>{
      'requestId': message['requestId'],
      'value': message['value'],
      'terminal': true,
    });
  });
  controller.initialized();
}

// Emits a progress event then a terminal event per message.
void _progressWorker(dynamic params) {
  final controller =
      IsolateBridgeController<Map<String, Object?>, Map<String, Object?>>(params);
  controller.messages.listen((message) {
    final id = message['requestId'];
    controller
      ..send(<String, Object?>{'requestId': id, 'progress': true, 'terminal': false})
      ..send(<String, Object?>{'requestId': id, 'result': 'done', 'terminal': true});
  });
  controller.initialized();
}

// Accepts messages but never responds (for timeout tests).
void _silentWorker(dynamic params) {
  final controller =
      IsolateBridgeController<Map<String, Object?>, Map<String, Object?>>(params);
  controller.messages.listen((_) {});
  controller.initialized();
}

// Per-slot counter: increments on each request (for sticky-key affinity tests).
void _statefulWorker(dynamic params) {
  final controller =
      IsolateBridgeController<Map<String, Object?>, Map<String, Object?>>(params);
  var counter = 0;
  controller.messages.listen((message) {
    counter++;
    controller.send(<String, Object?>{
      'requestId': message['requestId'],
      'counter': counter,
      'terminal': true,
    });
  });
  controller.initialized();
}

// Unused on the web Worker path — the JS worker handles it.
void _unused(dynamic _) {}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

Object? _requestId(Map<String, Object?> event) => event['requestId'];
bool _isTerminal(Map<String, Object?> event) => event['terminal'] == true;

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

void main() {
  group('IsolateBridgePool (web same-thread fallback)', () {
    test('spawns and closes cleanly', () async {
      final pool =
          await IsolateBridgePool.spawn<Map<String, Object?>, Map<String, Object?>>(
        _echoWorker,
        concurrent: 2,
        outputRequestId: _requestId,
        isTerminalEvent: _isTerminal,
      );
      await pool.close();
    });

    test('submit single request completes with correct response', () async {
      final pool =
          await IsolateBridgePool.spawn<Map<String, Object?>, Map<String, Object?>>(
        _echoWorker,
        outputRequestId: _requestId,
        isTerminalEvent: _isTerminal,
      );
      addTearDown(pool.close);

      final result = await pool.submit(
        <String, Object?>{'requestId': 'r1', 'value': 42},
        requestId: 'r1',
      );
      expect(result['requestId'], 'r1');
      expect(result['value'], 42);
    });

    test('submit distributes across multiple slots (round-robin)', () async {
      final pool =
          await IsolateBridgePool.spawn<Map<String, Object?>, Map<String, Object?>>(
        _echoWorker,
        concurrent: 3,
        outputRequestId: _requestId,
        isTerminalEvent: _isTerminal,
      );
      addTearDown(pool.close);

      final results = await Future.wait(<Future<Map<String, Object?>>>[
        pool.submit(<String, Object?>{'requestId': 'a', 'value': 1}, requestId: 'a'),
        pool.submit(<String, Object?>{'requestId': 'b', 'value': 2}, requestId: 'b'),
        pool.submit(<String, Object?>{'requestId': 'c', 'value': 3}, requestId: 'c'),
      ]);
      expect(
        results.map((r) => r['requestId']).toSet(),
        containsAll(<String>['a', 'b', 'c']),
      );
    });

    test('submit queues when slot at capacity, drains on completion', () async {
      final pool =
          await IsolateBridgePool.spawn<Map<String, Object?>, Map<String, Object?>>(
        _echoWorker,
        outputRequestId: _requestId,
        isTerminalEvent: _isTerminal,
      );
      addTearDown(pool.close);

      final f1 = pool.submit(
        <String, Object?>{'requestId': 'q1', 'value': 'first'},
        requestId: 'q1',
      );
      final f2 = pool.submit(
        <String, Object?>{'requestId': 'q2', 'value': 'second'},
        requestId: 'q2',
      );
      final r1 = await f1;
      final r2 = await f2;
      expect(r1['requestId'], 'q1');
      expect(r2['requestId'], 'q2');
    });

    test('submit slot-FIFO mode (no outputRequestId)', () async {
      final pool =
          await IsolateBridgePool.spawn<Map<String, Object?>, Map<String, Object?>>(
        _echoWorker,
      );
      addTearDown(pool.close);

      final result = await pool.submit(
        <String, Object?>{'requestId': 'fifo', 'value': 'hello'},
        requestId: 'fifo',
      );
      expect(result['value'], 'hello');
    });

    test('send is fire-and-forget and appears on stream', () async {
      final pool =
          await IsolateBridgePool.spawn<Map<String, Object?>, Map<String, Object?>>(
        _echoWorker,
        outputRequestId: _requestId,
        isTerminalEvent: _isTerminal,
      );
      addTearDown(pool.close);

      final event = pool.stream.first;
      pool.send(<String, Object?>{'requestId': 'ff', 'value': 'fire'});
      expect((await event)['requestId'], 'ff');
    });

    test('broadcast delivers to all healthy slots', () async {
      final pool =
          await IsolateBridgePool.spawn<Map<String, Object?>, Map<String, Object?>>(
        _echoWorker,
        concurrent: 3,
        outputRequestId: _requestId,
        isTerminalEvent: _isTerminal,
      );
      addTearDown(pool.close);

      final events = pool.stream.take(3).toList();
      pool.broadcast(<String, Object?>{'requestId': 'bc', 'value': 'all'});
      final results = await events;
      expect(results.length, 3);
      expect(results.every((r) => r['requestId'] == 'bc'), isTrue);
    });

    test('onEvent fires for non-terminal events, terminal completes future', () async {
      final pool =
          await IsolateBridgePool.spawn<Map<String, Object?>, Map<String, Object?>>(
        _progressWorker,
        outputRequestId: _requestId,
        isTerminalEvent: _isTerminal,
      );
      addTearDown(pool.close);

      final intermediate = <Map<String, Object?>>[];
      final result = await pool.submit(
        <String, Object?>{'requestId': 'p1'},
        requestId: 'p1',
        onEvent: (e) {
          if (e['terminal'] == false) intermediate.add(e);
        },
      );
      expect(intermediate, hasLength(1));
      expect(intermediate.first['progress'], isTrue);
      expect(result['result'], 'done');
    });

    test('submit times out when worker never responds', () async {
      final pool =
          await IsolateBridgePool.spawn<Map<String, Object?>, Map<String, Object?>>(
        _silentWorker,
        outputRequestId: _requestId,
        isTerminalEvent: _isTerminal,
      );
      addTearDown(pool.close);

      await expectLater(
        pool.submit(
          <String, Object?>{'requestId': 'to'},
          requestId: 'to',
          timeout: const Duration(milliseconds: 100),
        ),
        throwsA(isA<TimeoutException>()),
      );
    });

    test('close fails all pending and in-flight requests', () async {
      final pool =
          await IsolateBridgePool.spawn<Map<String, Object?>, Map<String, Object?>>(
        _silentWorker,
        outputRequestId: _requestId,
        isTerminalEvent: _isTerminal,
      );

      final inFlight =
          pool.submit(<String, Object?>{'requestId': 'cl1'}, requestId: 'cl1');
      final queued =
          pool.submit(<String, Object?>{'requestId': 'cl2'}, requestId: 'cl2');
      final f1 = expectLater(inFlight, throwsA(isA<IsolateException>()));
      final f2 = expectLater(queued, throwsA(isA<IsolateException>()));

      await pool.close();
      await f1;
      await f2;
    });

    test('leastInFlight routing completes all requests', () async {
      final pool =
          await IsolateBridgePool.spawn<Map<String, Object?>, Map<String, Object?>>(
        _echoWorker,
        concurrent: 2,
        maxInFlightPerWorker: 2,
        routing: BridgePoolRoutingStrategy.leastInFlight,
        outputRequestId: _requestId,
        isTerminalEvent: _isTerminal,
      );
      addTearDown(pool.close);

      final results = await Future.wait(<Future<Map<String, Object?>>>[
        pool.submit(<String, Object?>{'requestId': 'li1'}, requestId: 'li1'),
        pool.submit(<String, Object?>{'requestId': 'li2'}, requestId: 'li2'),
      ]);
      expect(
        results.map((r) => r['requestId']).toSet(),
        containsAll(<String>['li1', 'li2']),
      );
    });

    test('stickyKey sends both requests to same slot (counter increments)', () async {
      final pool =
          await IsolateBridgePool.spawn<Map<String, Object?>, Map<String, Object?>>(
        _statefulWorker,
        concurrent: 3,
        routing: BridgePoolRoutingStrategy.stickyKey,
        outputRequestId: _requestId,
        isTerminalEvent: _isTerminal,
      );
      addTearDown(pool.close);

      final r1 = await pool.submit(
        <String, Object?>{'requestId': 'sk1'},
        requestId: 'sk1',
        stickyKey: 'user-X',
      );
      final r2 = await pool.submit(
        <String, Object?>{'requestId': 'sk2'},
        requestId: 'sk2',
        stickyKey: 'user-X',
      );
      expect(r1['counter'], 1);
      expect(r2['counter'], 2);
    });

    test('close is idempotent', () async {
      final pool =
          await IsolateBridgePool.spawn<Map<String, Object?>, Map<String, Object?>>(
        _echoWorker,
        concurrent: 2,
      );
      await Future.wait([pool.close(), pool.close()]);
      await pool.close();
    });
  });

  group('IsolateBridgePool (Dart-compiled web Worker)', () {
    // This group exercises the isolateBridgeWorkerMain bootstrap path through
    // the pool. The compiled worker uses captureInitialMessageAsParams so the
    // first startup message is not forwarded to the app stream.

    test('single slot echoes messages', () async {
      final pool = await IsolateBridgePool.spawn<Object?, Object?>(
        _unused,
        workerName: 'workers/bridge_dart_echo',
      );
      addTearDown(pool.close);

      final event = pool.stream.first;
      pool.send('hello from pool');
      expect(await event, 'hello from pool');
    });

    test('concurrent:2 — broadcast reaches all slots', () async {
      final pool = await IsolateBridgePool.spawn<Object?, Object?>(
        _unused,
        concurrent: 2,
        workerName: 'workers/bridge_dart_echo',
      );
      addTearDown(pool.close);

      final events = pool.stream.take(2).toList();
      pool.broadcast('ping');
      final results = await events;
      expect(results.length, 2);
      expect(results.every((r) => r == 'ping'), isTrue);
    });

    test('spawns and closes cleanly', () async {
      final pool = await IsolateBridgePool.spawn<Object?, Object?>(
        _unused,
        concurrent: 2,
        workerName: 'workers/bridge_dart_echo',
      );
      await pool.close();
    });
  });

  group('IsolateBridgePool (web JS Worker)', () {
    test('spawns and closes cleanly with concurrent:2', () async {
      final pool = await IsolateBridgePool.spawn<Object?, Object?>(
        _unused,
        concurrent: 2,
        workerName: 'workers/bridge_echo',
      );
      await pool.close();
    });

    test('send appears on stream', () async {
      final pool = await IsolateBridgePool.spawn<Object?, Object?>(
        _unused,
        workerName: 'workers/bridge_echo',
      );
      addTearDown(pool.close);

      final event = pool.stream.first;
      pool.send('hello');
      expect(await event, 'hello');
    });

    test('multiple concurrent workers each echo their messages', () async {
      final pool = await IsolateBridgePool.spawn<Object?, Object?>(
        _unused,
        concurrent: 2,
        workerName: 'workers/bridge_echo',
      );
      addTearDown(pool.close);

      final events = pool.stream.take(2).toList();
      pool.broadcast('ping');
      final results = await events;
      expect(results.length, 2);
      expect(results.every((r) => r == 'ping'), isTrue);
    });

    test('post-init Worker crash surfaces as stream error', () async {
      final pool = await IsolateBridgePool.spawn<Object?, Object?>(
        _unused,
        workerName: 'workers/bridge_crash_after_init',
      );
      addTearDown(pool.close);

      pool.send('trigger');
      await expectLater(pool.stream, emitsError(isA<IsolateException>()));
    });

    test('close is idempotent', () async {
      final pool = await IsolateBridgePool.spawn<Object?, Object?>(
        _unused,
        concurrent: 2,
        workerName: 'workers/bridge_echo',
      );
      await Future.wait([pool.close(), pool.close()]);
      await pool.close();
    });

    test('stream emits done after all slots close', () async {
      final pool = await IsolateBridgePool.spawn<Object?, Object?>(
        _unused,
        workerName: 'workers/bridge_echo',
      );

      final done = Completer<void>();
      pool.stream.listen((_) {}, onDone: done.complete);
      await pool.close();
      await done.future;
    });
  });
}
