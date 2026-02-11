import 'dart:js_interop';
import 'dart:typed_data';

/// Extract JSArrayBuffers from Dart ByteBuffer/Uint8List objects for
/// zero-copy transfer via `postMessage`.
JSArray<JSArrayBuffer> extractArrayBuffers(List<Object> transferables) {
  final buffers = <JSArrayBuffer>[];

  for (final item in transferables) {
    if (item is ByteBuffer) {
      buffers.add(item.toJS);
    } else if (item is Uint8List) {
      buffers.add(item.buffer.toJS);
    }
    // Ignore non-transferable items silently
  }

  return buffers.toJS;
}
