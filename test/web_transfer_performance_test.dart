// For debug only
// ignore_for_file: avoid_print, document_ignores

@TestOn('chrome')
library;

import 'dart:typed_data';

import 'package:isolate_manager/isolate_manager.dart';
import 'package:test/test.dart';

import 'functions.dart';

const bool _isWasm = bool.fromEnvironment('dart.tool.dart2wasm');

void main() {
  IsolateManager.addWorkerMapping(identityBytes, 'workers/identityBytes');

  group('Web Transfer Performance (Worker)', () {
    late IsolateManager<Uint8List, Uint8List> manager;

    setUp(() async {
      manager = IsolateManager.create(
        identityBytes,
        workerName: 'workers/identityBytes',
      );
      await manager.start();
    });

    tearDown(() async {
      await manager.stop();
    });

    for (final sizeKB in [1, 100, 1024, 10240]) {
      test('round-trip ${sizeKB}KB with transferables (zero-copy)', () async {
        final data = Uint8List(sizeKB * 1024);
        for (var i = 0; i < data.length; i++) {
          data[i] = i % 256;
        }

        final originalLength = data.buffer.lengthInBytes;

        final sw = Stopwatch()..start();
        final result = await manager.compute(
          data,
          transferables: [data.buffer],
        );
        sw.stop();

        expect(result.length, originalLength);

        if (_isWasm) {
          expect(
            data.buffer.lengthInBytes,
            originalLength,
            reason:
                'WASM currently does not detach the source buffer after transfer list send.',
          );
        } else {
          // After transfer, the source buffer should be detached (zero-length)
          expect(
            data.buffer.lengthInBytes,
            0,
            reason: 'Source buffer should be detached after zero-copy transfer',
          );
        }

        print(
          '  ${sizeKB}KB with transferables: ${sw.elapsedMilliseconds}ms',
        );
      });

      test('round-trip ${sizeKB}KB without transferables (copy)', () async {
        final data = Uint8List(sizeKB * 1024);
        for (var i = 0; i < data.length; i++) {
          data[i] = i % 256;
        }

        final sw = Stopwatch()..start();
        final result = await manager.compute(data);
        sw.stop();

        expect(result.length, data.length);

        // Without transferables, source buffer remains intact
        expect(
          data.buffer.lengthInBytes,
          sizeKB * 1024,
          reason: 'Source buffer should remain intact without transferables',
        );

        print(
          '  ${sizeKB}KB without transferables: ${sw.elapsedMilliseconds}ms',
        );
      });
    }
  });
}
