// For debug only
// ignore_for_file: avoid_print, document_ignores

@TestOn('vm')
library;

import 'dart:typed_data';

import 'package:isolate_manager/isolate_manager.dart';
import 'package:test/test.dart';

import 'functions.dart';

void main() {
  group('Transfer Performance (VM)', () {
    late IsolateManager<Uint8List, Uint8List> manager;

    setUp(() async {
      manager = IsolateManager.create(identityBytes);
      await manager.start();
    });

    tearDown(() async {
      await manager.stop();
    });

    for (final sizeKB in [1, 100, 1024, 10240]) {
      test('round-trip ${sizeKB}KB with transferables', () async {
        final data = Uint8List(sizeKB * 1024);
        for (var i = 0; i < data.length; i++) {
          data[i] = i % 256;
        }

        final sw = Stopwatch()..start();
        final result = await manager.compute(
          data,
          transferables: [data.buffer],
        );
        sw.stop();

        expect(result.length, data.length);
        print('  ${sizeKB}KB with transferables: ${sw.elapsedMilliseconds}ms');
      });

      test('round-trip ${sizeKB}KB without transferables', () async {
        final data = Uint8List(sizeKB * 1024);
        for (var i = 0; i < data.length; i++) {
          data[i] = i % 256;
        }

        final sw = Stopwatch()..start();
        final result = await manager.compute(data);
        sw.stop();

        expect(result.length, data.length);
        print(
          '  ${sizeKB}KB without transferables: ${sw.elapsedMilliseconds}ms',
        );
      });
    }
  });
}
