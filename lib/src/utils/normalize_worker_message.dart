import 'dart:typed_data';

/// Normalizes structured-clone values produced by `dartify()`.
///
/// JavaScript object keys are strings, but `dartify()` represents them as
/// `Map<Object?, Object?>`. Converting keys recursively keeps typed bridge
/// payloads such as `Map<String, Object?>` valid on both sides of a Worker.
dynamic normalizeWorkerMessage(dynamic value) {
  if (value is TypedData || value is ByteBuffer) {
    return value;
  }

  if (value is Map) {
    return <String, dynamic>{
      for (final entry in value.entries)
        entry.key.toString(): normalizeWorkerMessage(entry.value),
    };
  }

  if (value is List) {
    return value.map(normalizeWorkerMessage).toList();
  }

  return value;
}
