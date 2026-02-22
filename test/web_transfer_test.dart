@TestOn('browser')
library;

import 'dart:math';
import 'dart:typed_data';

import 'package:isolate_manager/isolate_manager.dart';
import 'package:test/test.dart';

import 'web_js_interop_helpers.dart'
    if (dart.library.io) 'web_js_interop_helpers_stub.dart';

const bool _isWasm = bool.fromEnvironment('dart.tool.dart2wasm');

// Worker is pre-generated at test/workers/processBytes.js.
// @isolateManagerWorker is intentionally omitted to prevent the code
// generator from injecting an import of this file into isolate_manager_test.dart,
// which would cause dart:js_interop to be pulled into VM compilation.
Uint8List processBytes(Uint8List data) {
  // Simple processor: create response with same length
  final result = Uint8List(data.length);
  for (var i = 0; i < data.length; i++) {
    result[i] = (data[i] + 1) % 256; // Increment each byte
  }
  return result;
}

void main() {
  IsolateManager.addWorkerMapping(processBytes, 'workers/processBytes');

  group('Web ArrayBuffer Transfer', () {
    test('should transfer large Uint8List with zero-copy', () async {
      final manager = IsolateManager.create(
        processBytes,
        workerName: 'workers/processBytes',
      );

      await manager.start();

      final largeData = Uint8List(1024 * 1024); // 1MB
      for (var i = 0; i < largeData.length; i++) {
        largeData[i] = i % 256;
      }

      final originalLength = largeData.buffer.lengthInBytes;

      // Pass transferables explicitly through compute()
      final result = await manager.compute(
        largeData,
        transferables: [largeData.buffer],
      );

      expect(result.length, originalLength);

      // Verify the processing worked
      for (var i = 0; i < min(100, result.length); i++) {
        expect(result[i], (i + 1) % 256);
      }

      // After transfer, the source buffer should be detached (zero-length)
      if (_isWasm) {
        expect(
          largeData.buffer.lengthInBytes,
          originalLength,
          reason:
              'WASM currently does not detach the source buffer after transfer list send.',
        );
      } else {
        expect(
          largeData.buffer.lengthInBytes,
          0,
          reason: 'Source buffer should be detached after zero-copy transfer',
        );
      }

      await manager.stop();
    });

    test('should work without transferables (copy mode)', () async {
      final manager = IsolateManager.create(
        processBytes,
        workerName: 'workers/processBytes',
      );

      await manager.start();

      final data = Uint8List(1024);
      for (var i = 0; i < data.length; i++) {
        data[i] = i % 256;
      }

      // No transferables — data is copied
      final result = await manager.compute(data);

      expect(result.length, data.length);
      for (var i = 0; i < min(100, result.length); i++) {
        expect(result[i], (i + 1) % 256);
      }

      // Source buffer remains intact when not using transferables
      expect(data.buffer.lengthInBytes, 1024);

      await manager.stop();
    });

    test('ByteBuffer can be extracted to JSArrayBuffer', () {
      final bytes = Uint8List(100);
      final buffer = bytes.buffer;

      // Verify we can get the buffer
      expect(buffer.lengthInBytes, 100);

      // This simulates what our extractArrayBuffers does
      expect(buffer, isA<ByteBuffer>());
    });

    test('should accept JSArrayBuffer in transferables list', () async {
      final manager = IsolateManager.create(
        processBytes,
        workerName: 'workers/processBytes',
      );

      await manager.start();

      final data = Uint8List(2048);
      for (var i = 0; i < data.length; i++) {
        data[i] = i % 256;
      }

      final result = await manager.compute(
        data,
        transferables: <Object>[bufferToJSArrayBuffer(data.buffer)],
      );

      expect(result.length, data.length);
      await manager.stop();
    });
  });
}
