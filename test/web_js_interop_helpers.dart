import 'dart:js_interop';
import 'dart:typed_data';

/// Converts a [ByteBuffer] to a [JSArrayBuffer] for use in a transfer list.
Object bufferToJSArrayBuffer(ByteBuffer buffer) => buffer.toJS;
