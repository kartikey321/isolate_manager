import 'dart:collection';
import 'dart:isolate';
import 'dart:typed_data';

const _envelopeMarkerKey = '__im_native_transfer_envelope__';
const _payloadKey = 'payload';
const _packetsKey = 'packets';
const _refMarkerKey = '__im_native_transfer_ref__';
const _typeKey = 't';
const _indexKey = 'i';
const _offsetKey = 'o';
const _lengthKey = 'l';

/// Encodes selected [Uint8List]/[ByteBuffer] values into [TransferableTypedData]
/// references for native isolate transport.
dynamic encodeNativeTransferPayload(
  dynamic payload, {
  List<Object>? transferables,
}) {
  if (transferables == null || transferables.isEmpty) return payload;

  final targetBuffers = HashSet<ByteBuffer>.identity();
  for (final transferable in transferables) {
    if (transferable is ByteBuffer) {
      targetBuffers.add(transferable);
    } else if (transferable is Uint8List) {
      targetBuffers.add(transferable.buffer);
    }
  }

  if (targetBuffers.isEmpty) return payload;

  final packetIndexes = HashMap<ByteBuffer, int>.identity();
  final packets = <TransferableTypedData>[];

  int ensurePacket(ByteBuffer buffer) {
    final existingIndex = packetIndexes[buffer];
    if (existingIndex != null) return existingIndex;

    final packet = TransferableTypedData.fromList([Uint8List.view(buffer)]);
    packets.add(packet);
    final index = packets.length - 1;
    packetIndexes[buffer] = index;
    return index;
  }

  dynamic encodeValue(dynamic value) {
    if (value is Uint8List) {
      if (!targetBuffers.contains(value.buffer)) return value;
      return <String, Object>{
        _refMarkerKey: true,
        _typeKey: 'u8',
        _indexKey: ensurePacket(value.buffer),
        _offsetKey: value.offsetInBytes,
        _lengthKey: value.lengthInBytes,
      };
    }

    if (value is ByteBuffer) {
      if (!targetBuffers.contains(value)) return value;
      return <String, Object>{
        _refMarkerKey: true,
        _typeKey: 'bb',
        _indexKey: ensurePacket(value),
        _offsetKey: 0,
        _lengthKey: value.lengthInBytes,
      };
    }

    if (value is List) {
      return value.map<Object?>(encodeValue).toList();
    }

    if (value is Map) {
      final mapped = <Object?, Object?>{};
      value.forEach((key, mapValue) {
        mapped[key] = encodeValue(mapValue);
      });
      return mapped;
    }

    return value;
  }

  final encodedPayload = encodeValue(payload);
  if (packets.isEmpty) return payload;

  return <String, Object?>{
    _envelopeMarkerKey: true,
    _payloadKey: encodedPayload,
    _packetsKey: packets,
  };
}

/// Decodes payload encoded by [encodeNativeTransferPayload].
dynamic decodeNativeTransferPayload(dynamic payload) {
  if (payload is! Map) return payload;
  if (payload[_envelopeMarkerKey] != true) return payload;

  final rawPackets = payload[_packetsKey];
  if (rawPackets is! List) return payload[_payloadKey];

  final buffers = <ByteBuffer>[];
  for (final rawPacket in rawPackets) {
    if (rawPacket is TransferableTypedData) {
      buffers.add(rawPacket.materialize());
    }
  }

  dynamic decodeValue(dynamic value) {
    if (value is Map && value[_refMarkerKey] == true) {
      final type = value[_typeKey];
      final index = value[_indexKey];
      final offset = value[_offsetKey];
      final length = value[_lengthKey];

      if (type is! String || index is! int) return value;
      if (index < 0 || index >= buffers.length) return value;
      if (offset is! int || length is! int) return value;
      if (offset < 0 || length < 0) return value;

      final buffer = buffers[index];
      if (offset + length > buffer.lengthInBytes) return value;

      if (type == 'u8') {
        return Uint8List.view(buffer, offset, length);
      }
      if (type == 'bb') return buffer;
      return value;
    }

    if (value is List) {
      return value.map<Object?>(decodeValue).toList();
    }

    if (value is Map) {
      final mapped = <Object?, Object?>{};
      value.forEach((key, mapValue) {
        mapped[key] = decodeValue(mapValue);
      });
      return mapped;
    }

    return value;
  }

  return decodeValue(payload[_payloadKey]);
}
