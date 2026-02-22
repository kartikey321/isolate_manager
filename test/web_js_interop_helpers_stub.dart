import 'dart:typed_data';

/// Stub for non-web platforms. Never called at runtime because
/// web_transfer_test.dart is @TestOn('browser') only.
Object bufferToJSArrayBuffer(ByteBuffer buffer) => buffer;
