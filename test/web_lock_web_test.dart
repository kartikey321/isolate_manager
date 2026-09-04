@TestOn('browser')
library;

import 'dart:async';

import 'package:isolate_manager/isolate_manager.dart';
import 'package:test/test.dart';

void main() {
  group('WebLock (browser)', () {
    test('isSupported is true in a real browser', () {
      expect(WebLock.isSupported, isTrue);
    });

    test('tryAcquire grants immediately when the lock is free', () async {
      final name = 'test-lock-${DateTime.now().microsecondsSinceEpoch}';
      final handle = await WebLock.tryAcquire(name);
      expect(handle, isNotNull);
      expect(handle!.isReleased, isFalse);
      await handle.release();
      expect(handle.isReleased, isTrue);
    });

    test('tryAcquire returns null when already held', () async {
      final name = 'test-lock-${DateTime.now().microsecondsSinceEpoch}';
      final first = await WebLock.tryAcquire(name);
      expect(first, isNotNull);

      final second = await WebLock.tryAcquire(name);
      expect(second, isNull);

      await first!.release();
    });

    test('acquire queues and grants once the holder releases', () async {
      final name = 'test-lock-${DateTime.now().microsecondsSinceEpoch}';
      final first = await WebLock.tryAcquire(name);
      expect(first, isNotNull);

      var secondGranted = false;
      final secondFuture = WebLock.acquire(name).then((handle) {
        secondGranted = true;
        return handle;
      });

      // Give the queued request a moment to prove it does NOT resolve while
      // the first holder is still holding.
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(secondGranted, isFalse);

      await first!.release();

      final second = await secondFuture.timeout(const Duration(seconds: 5));
      expect(secondGranted, isTrue);
      expect(second, isNotNull);
      await second!.release();
    });

    test('acquire with a cancelled token resolves to null', () async {
      final name = 'test-lock-${DateTime.now().microsecondsSinceEpoch}';
      final first = await WebLock.tryAcquire(name);
      expect(first, isNotNull);

      final cancelToken = WebLockCancelToken();
      final pending = WebLock.acquire(name, cancelToken: cancelToken);
      cancelToken.cancel();

      final result = await pending.timeout(const Duration(seconds: 5));
      expect(result, isNull);

      await first!.release();
    });
  });

  group('WebBroadcastChannel (browser)', () {
    test(
      'a message sent on one channel arrives on another with the same name',
      () async {
        final name = 'test-channel-${DateTime.now().microsecondsSinceEpoch}';
        final a = WebBroadcastChannel(name);
        final b = WebBroadcastChannel(name);
        addTearDown(a.close);
        addTearDown(b.close);

        final received = Completer<Object?>();
        b.messages.listen((msg) {
          if (!received.isCompleted) received.complete(msg);
        });

        a.send(<String, Object?>{'hello': 'world'});

        final msg = await received.future.timeout(const Duration(seconds: 5));
        expect(msg, isA<Map<dynamic, dynamic>>());
        expect((msg! as Map<dynamic, dynamic>)['hello'], 'world');
      },
    );

    test('a channel never receives its own message', () async {
      final name = 'test-channel-${DateTime.now().microsecondsSinceEpoch}';
      final a = WebBroadcastChannel(name);
      addTearDown(a.close);

      var received = false;
      a.messages.listen((_) => received = true);
      a.send('self');

      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(received, isFalse);
    });
  });
}
