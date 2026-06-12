import 'dart:async';

import 'package:isolate_manager/isolate_manager.dart';
import 'package:test/test.dart';

// ---------------------------------------------------------------------------
// Worker entry points
// ---------------------------------------------------------------------------

/// Echo worker: sends back exactly what it receives.
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

/// Emits a progress event then a terminal event per message.
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

/// Crashes before calling initialized().
void _crashingWorker(dynamic params) {
  throw StateError('worker crashed on startup');
}

/// Accepts messages but never responds (used for timeout / close tests).
void _silentWorker(dynamic params) {
  final controller =
      IsolateBridgeController<Map<String, Object?>, Map<String, Object?>>(params);
  controller.messages.listen((_) {});
  controller.initialized();
}

/// Maintains a per-slot counter; returns it on each request (for affinity tests).
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

/// Echo worker that crashes the isolate when message contains kill:true.
void _killableWorker(dynamic params) {
  final controller =
      IsolateBridgeController<Map<String, Object?>, Map<String, Object?>>(params);
  controller.messages.listen((message) {
    if (message['kill'] == true) throw StateError('deliberate worker crash');
    controller.send(<String, Object?>{
      'requestId': message['requestId'],
      'terminal': true,
    });
  });
  controller.initialized();
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

Object? _requestId(Map<String, Object?> event) => event['requestId'];
bool _isTerminal(Map<String, Object?> event) => event['terminal'] == true;

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

void main() {
  group('IsolateBridgePool', () {
    test('spawns and closes cleanly', () async {
      final pool = await IsolateBridgePool.spawn<Map<String, Object?>, Map<String, Object?>>(
        _echoWorker,
        concurrent: 2,
        outputRequestId: _requestId,
        isTerminalEvent: _isTerminal,
      );

      await pool.close();
    });

    test('submit: single request completes with correct response', () async {
      final pool = await IsolateBridgePool.spawn<Map<String, Object?>, Map<String, Object?>>(
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
      final pool = await IsolateBridgePool.spawn<Map<String, Object?>, Map<String, Object?>>(
        _echoWorker,
        concurrent: 4,
        outputRequestId: _requestId,
        isTerminalEvent: _isTerminal,
      );

      addTearDown(pool.close);

      final futures = <Future<Map<String, Object?>>>[];
      for (var i = 0; i < 4; i++) {
        futures.add(pool.submit(
          <String, Object?>{'requestId': 'r$i', 'value': i},
          requestId: 'r$i',
        ));
      }

      final results = await Future.wait(futures);
      expect(results.map((r) => r['requestId']).toSet(), containsAll(['r0', 'r1', 'r2', 'r3']));
    });

    test('submit queues when slot at capacity, drains on completion', () async {
      final pool = await IsolateBridgePool.spawn<Map<String, Object?>, Map<String, Object?>>(
        _echoWorker,
        // single slot, single capacity — second request must queue
        outputRequestId: _requestId,
        isTerminalEvent: _isTerminal,
      );

      addTearDown(pool.close);

      final f1 = pool.submit(<String, Object?>{'requestId': 'q1', 'value': 'first'}, requestId: 'q1');
      final f2 = pool.submit(<String, Object?>{'requestId': 'q2', 'value': 'second'}, requestId: 'q2');

      final r1 = await f1;
      final r2 = await f2;

      expect(r1['requestId'], 'q1');
      expect(r2['requestId'], 'q2');
    });

    test('submit slot-FIFO mode (no outputRequestId)', () async {
      final pool = await IsolateBridgePool.spawn<Map<String, Object?>, Map<String, Object?>>(
        _echoWorker,
      );

      addTearDown(pool.close);

      final result = await pool.submit(
        <String, Object?>{'requestId': 'fifo1', 'value': 'hello'},
        requestId: 'fifo1',
      );

      expect(result['value'], 'hello');
    });

    test('send is fire-and-forget and appears on stream', () async {
      final pool = await IsolateBridgePool.spawn<Map<String, Object?>, Map<String, Object?>>(
        _echoWorker,
        outputRequestId: _requestId,
        isTerminalEvent: _isTerminal,
      );

      addTearDown(pool.close);

      final event = pool.stream.first;
      pool.send(<String, Object?>{'requestId': 'ff1', 'value': 'fire'});

      final result = await event;
      expect(result['requestId'], 'ff1');
    });

    test('broadcast delivers to all healthy slots', () async {
      const n = 3;
      final pool = await IsolateBridgePool.spawn<Map<String, Object?>, Map<String, Object?>>(
        _echoWorker,
        concurrent: n,
        outputRequestId: _requestId,
        isTerminalEvent: _isTerminal,
      );

      addTearDown(pool.close);

      final events = pool.stream.take(n).toList();
      pool.broadcast(<String, Object?>{'requestId': 'bc', 'value': 'all'});

      final results = await events;
      expect(results.length, n);
      expect(results.every((r) => r['requestId'] == 'bc'), isTrue);
    });

    test('onEvent fires for non-terminal events, terminal completes future', () async {
      final pool = await IsolateBridgePool.spawn<Map<String, Object?>, Map<String, Object?>>(
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
      final pool = await IsolateBridgePool.spawn<Map<String, Object?>, Map<String, Object?>>(
        _silentWorker,
        outputRequestId: _requestId,
        isTerminalEvent: _isTerminal,
      );

      addTearDown(pool.close);

      await expectLater(
        pool.submit(
          <String, Object?>{'requestId': 'to1'},
          requestId: 'to1',
          timeout: const Duration(milliseconds: 100),
        ),
        throwsA(isA<TimeoutException>()),
      );
    });

    test('close fails all pending and in-flight requests', () async {
      final pool = await IsolateBridgePool.spawn<Map<String, Object?>, Map<String, Object?>>(
        _silentWorker,
        outputRequestId: _requestId,
        isTerminalEvent: _isTerminal,
      );

      final inFlight = pool.submit(<String, Object?>{'requestId': 'cl1'}, requestId: 'cl1');
      // Queue a second request (slot at capacity with first one in-flight).
      final queued = pool.submit(<String, Object?>{'requestId': 'cl2'}, requestId: 'cl2');

      // Register error handlers BEFORE closing so errors don't become unhandled.
      final f1 = expectLater(inFlight, throwsA(isA<IsolateException>()));
      final f2 = expectLater(queued, throwsA(isA<IsolateException>()));

      await pool.close();
      await f1;
      await f2;
    });

    test('spawn fails when worker crashes before init', () async {
      await expectLater(
        IsolateBridgePool.spawn<Map<String, Object?>, Map<String, Object?>>(
          _crashingWorker,
        ),
        throwsA(isA<IsolateException>()),
      );
    });

    test('stickyKey routes same key to same slot across sequential requests', () async {
      final pool = await IsolateBridgePool.spawn<Map<String, Object?>, Map<String, Object?>>(
        _echoWorker,
        concurrent: 3,
        routing: BridgePoolRoutingStrategy.stickyKey,
        outputRequestId: _requestId,
        isTerminalEvent: _isTerminal,
      );

      addTearDown(pool.close);

      final r1 = await pool.submit(
        <String, Object?>{'requestId': 'sk1'},
        requestId: 'sk1',
        stickyKey: 'session-A',
      );
      final r2 = await pool.submit(
        <String, Object?>{'requestId': 'sk2'},
        requestId: 'sk2',
        stickyKey: 'session-A',
      );

      expect(r1['requestId'], 'sk1');
      expect(r2['requestId'], 'sk2');
    });

    test('leastInFlight routing completes all requests', () async {
      final pool = await IsolateBridgePool.spawn<Map<String, Object?>, Map<String, Object?>>(
        _echoWorker,
        concurrent: 2,
        maxInFlightPerWorker: 2,
        routing: BridgePoolRoutingStrategy.leastInFlight,
        outputRequestId: _requestId,
        isTerminalEvent: _isTerminal,
      );

      addTearDown(pool.close);

      final results = await Future.wait([
        pool.submit(<String, Object?>{'requestId': 'li1'}, requestId: 'li1'),
        pool.submit(<String, Object?>{'requestId': 'li2'}, requestId: 'li2'),
      ]);

      expect(results.map((r) => r['requestId']).toSet(), containsAll(['li1', 'li2']));
    });

    test('stickyKey sends both requests to the same slot (counter increments)', () async {
      // Uses a stateful worker whose per-slot counter increments on each
      // request. If both requests hit the same slot the counters are 1 and 2;
      // if they hit different slots both counters would be 1.
      final pool = await IsolateBridgePool.spawn<Map<String, Object?>, Map<String, Object?>>(
        _statefulWorker,
        concurrent: 3,
        routing: BridgePoolRoutingStrategy.stickyKey,
        outputRequestId: _requestId,
        isTerminalEvent: _isTerminal,
      );

      addTearDown(pool.close);

      final r1 = await pool.submit(
        <String, Object?>{'requestId': 'aff1'},
        requestId: 'aff1',
        stickyKey: 'user-X',
      );
      final r2 = await pool.submit(
        <String, Object?>{'requestId': 'aff2'},
        requestId: 'aff2',
        stickyKey: 'user-X',
      );

      expect(r1['counter'], 1);
      expect(r2['counter'], 2); // incremented on the *same* slot
    });

    test('stickyMap is pruned on slot death — subsequent request re-routes to healthy slot',
        () async {
      // 2-slot pool, autoRespawn=false. Establish sticky affinity on slot 0,
      // then crash slot 0. The pruned stickyMap lets the next request re-route
      // to slot 1 instead of hanging.
      final pool = await IsolateBridgePool.spawn<Map<String, Object?>, Map<String, Object?>>(
        _killableWorker,
        concurrent: 2,
        routing: BridgePoolRoutingStrategy.stickyKey,
        outputRequestId: _requestId,
        isTerminalEvent: _isTerminal,
      );

      addTearDown(pool.close);

      // First request establishes stickyMap["session-B"] → some slot.
      await pool.submit(
        <String, Object?>{'requestId': 'sb1'},
        requestId: 'sb1',
        stickyKey: 'session-B',
      );

      // Kill the sticky slot by sending kill:true to it (routed via same key).
      // The slot crash fails this future; we just swallow it.
      await expectLater(
        pool.submit(
          <String, Object?>{'requestId': 'kill', 'kill': true},
          requestId: 'kill',
          stickyKey: 'session-B',
        ),
        throwsA(isA<IsolateException>()),
      );

      // After the crash, stickyMap['session-B'] must have been cleared.
      // The request re-routes to the still-healthy remaining slot and completes.
      final r3 = await pool.submit(
        <String, Object?>{'requestId': 'sb3'},
        requestId: 'sb3',
        stickyKey: 'session-B',
      );

      expect(r3['requestId'], 'sb3');
    });

    test('autoRespawn=true recovers after slot crash and processes new requests', () async {
      final pool = await IsolateBridgePool.spawn<Map<String, Object?>, Map<String, Object?>>(
        _killableWorker,
        outputRequestId: _requestId,
        isTerminalEvent: _isTerminal,
        autoRespawn: true,
      );

      addTearDown(pool.close);

      // Crash the only slot.
      await expectLater(
        pool.submit(
          <String, Object?>{'requestId': 'crash', 'kill': true},
          requestId: 'crash',
        ),
        throwsA(isA<IsolateException>()),
      );

      // Wait for the respawn to complete (happens asynchronously after crash).
      Map<String, Object?>? result;
      for (var attempt = 0; attempt < 20; attempt++) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
        try {
          result = await pool
              .submit(
                <String, Object?>{'requestId': 'recover'},
                requestId: 'recover',
                timeout: const Duration(milliseconds: 200),
              )
              .timeout(const Duration(milliseconds: 300));
          break;
        } on Object catch (_) {
          // Respawn not ready yet; try again.
        }
      }

      expect(result, isNotNull);
      expect(result!['requestId'], 'recover');
    });
  });
}
