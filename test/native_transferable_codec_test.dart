@TestOn('vm')
library;

import 'dart:typed_data';

import 'package:isolate_manager/src/utils/native_transferable_codec.dart';
import 'package:test/test.dart';

void main() {
  group('native transferable codec', () {
    test('encode/decode round-trip for targeted Uint8List view', () {
      final source = Uint8List.fromList(List<int>.generate(16, (i) => i));
      final view = Uint8List.view(source.buffer, 4, 6);
      final payload = <String, Object?>{
        'bytes': view,
        'untouched': Uint8List.fromList(<int>[100, 101]),
      };

      final encoded = encodeNativeTransferPayload(
        payload,
        transferables: <Object>[source.buffer],
      );
      final decoded = decodeNativeTransferPayload(encoded) as Map<Object?, Object?>;

      final decodedBytes = decoded['bytes'] as Uint8List?;
      expect(decodedBytes, isNotNull);
      expect(decodedBytes, orderedEquals(view));
      expect(decodedBytes!.lengthInBytes, 6);
      expect(decoded['untouched'], isA<Uint8List>());
    });

    test('no transferables keeps payload identity', () {
      final payload = <String, Object?>{'bytes': Uint8List(8)};
      final encoded = encodeNativeTransferPayload(payload);
      expect(identical(encoded, payload), isTrue);
    });

    test('non-matching transferables keep payload identity', () {
      final payload = <String, Object?>{'bytes': Uint8List(8)};
      final other = Uint8List(4);

      final encoded = encodeNativeTransferPayload(
        payload,
        transferables: <Object>[other.buffer],
      );
      expect(identical(encoded, payload), isTrue);
    });
  });
}
