import 'dart:js_interop';
import 'dart:typed_data';

import 'package:web/web.dart' show MessagePort;

/// Builds a `postMessage` transfer list from a mixed [transferables] list.
///
/// Handles two kinds of entries:
///  - Dart `ByteBuffer`/`Uint8List` (or a raw `JSArrayBuffer`) for zero-copy
///    binary transfer.
///  - A raw [MessagePort] — e.g. one half of a `MessageChannel` being handed
///    off to another JS context (worker-to-worker port transfer for a
///    SharedWorker proxy). `MessagePort` is natively transferable; it is
///    passed through unchanged, not converted.
///
/// Any other item is silently ignored.
JSArray<JSAny> extractArrayBuffers(List<Object> transferables) {
  final items = <JSAny>[];

  for (final item in transferables) {
    // JS interop values in transfer lists are runtime-provided objects. We
    // need these `is` checks so callers can pass raw JS interop types
    // directly, alongside plain Dart buffer types.
    // ignore: invalid_runtime_check_with_js_interop_types
    if (item is JSArrayBuffer) {
      items.add(item);
    } else if (item is ByteBuffer) {
      items.add(item.toJS);
      // Same reasoning as the JSArrayBuffer check above: MessagePort is a
      // runtime-provided JS interop type, not something Dart erases safely.
      // ignore: invalid_runtime_check_with_js_interop_types
    } else if (item is MessagePort) {
      items.add(item);
    } else if (item is Uint8List) {
      items.add(item.buffer.toJS);
    }
    // Ignore non-transferable items silently
  }

  return items.toJS;
}

/// Filters a `transferables` list down for a wasm build that hasn't opted
/// into buffer transfer via [allowBuffers].
///
/// A [MessagePort] is always kept: unlike `ByteBuffer`/`Uint8List` (which
/// most dart2wasm targets can't yet detach through the Dart<->JS interop
/// boundary — the reason [allowBuffers] exists), a port is never converted
/// through that boundary at all; it's a JS interop value forwarded to the
/// browser as-is, so there is nothing wasm-unsafe about transferring one.
/// Buffer-like entries are dropped unless [allowBuffers] or this isn't a
/// wasm build. Returns `null` when [transferables] is `null`, or when
/// nothing survives the filter (matching the historical "drop the whole
/// list" behavior at call sites that null-check before building a transfer
/// array).
List<Object>? filterTransferablesForWasm(
  List<Object>? transferables, {
  required bool allowBuffers,
  required bool isWasm,
}) {
  if (transferables == null) return null;
  if (allowBuffers || !isWasm) return transferables;

  final ports = <Object>[];
  for (final item in transferables) {
    // JS interop values are runtime-provided objects. Same reasoning as the
    // `is` check in extractArrayBuffers above — whereType<MessagePort>()
    // would erase to the extension type's representation type at runtime.
    // ignore: invalid_runtime_check_with_js_interop_types
    if (item is MessagePort) ports.add(item);
  }

  return ports.isEmpty ? null : ports;
}
