// Binary frame format for Volcengine streaming ASR (v3 bigmodel endpoint).
//
// Reference: Volcengine docs at https://www.volcengine.com/docs/6561/80818
//
// Frame layout (big-endian throughout):
//
//   Byte 0     : protocol_version (high 4 bits) | header_size (low 4 bits, *4 bytes)
//                value 0x11 means proto v1, header = 4 bytes
//   Byte 1     : message_type (high 4 bits) | message_type_specific_flags (low 4 bits)
//   Byte 2     : serialization_method (high 4 bits) | compression (low 4 bits)
//   Byte 3     : reserved
//
//   Then optional segments (presence driven by flags):
//     - sequence (4 bytes int32, signed)        when flags & 0x01 (positive seq) or 0x03 (last frame, negative seq)
//     - event id (4 bytes uint32)               when flags & 0x04
//     - session id len (4 bytes uint32) + bytes when flags & 0x10
//
//   For ERROR (message_type 0x0F): 4-byte error code before payload size.
//
//   Then payload_size (4 bytes uint32) + payload bytes.
//
// Message types we care about:
//   0x01 FULL_CLIENT_REQUEST  - upstream config (JSON)
//   0x02 AUDIO_ONLY_REQUEST   - PCM chunk
//   0x09 FULL_SERVER_RESPONSE - server's JSON (partial / final / definite end)
//   0x0F ERROR_MESSAGE        - server error

import 'dart:convert';
import 'dart:typed_data';

const int msgFullClientRequest  = 0x01;
const int msgAudioOnlyRequest   = 0x02;
const int msgFullServerResponse = 0x09;
const int msgServerAck          = 0x0B;
const int msgErrorMessage       = 0x0F;

const int serialJSON = 0x01;
const int serialNone = 0x00;
const int compressNone = 0x00;

/// Build a FULL_CLIENT_REQUEST frame carrying the JSON session config.
/// Sequence 1 is the conventional first value; the server expects the first
/// frame to carry it (flags=0x01 = positive sequence).
Uint8List buildFullClientRequest(Map<String, dynamic> config, {int sequence = 1}) {
  final payload = utf8.encode(jsonEncode(config));
  return _frame(
    messageType: msgFullClientRequest,
    flags: 0x01, // has positive sequence
    serialization: serialJSON,
    compression: compressNone,
    sequence: sequence,
    payload: Uint8List.fromList(payload),
  );
}

/// Build an AUDIO_ONLY_REQUEST frame for one PCM chunk.
/// [isLast] true makes the sequence negative, signalling end-of-stream.
Uint8List buildAudioRequest(Uint8List pcm, int sequence, {bool isLast = false}) {
  final actualSeq = isLast ? -sequence.abs() : sequence;
  // 0x01 = positive seq; 0x03 = negative seq (last)
  final flags = isLast ? 0x03 : 0x01;
  return _frame(
    messageType: msgAudioOnlyRequest,
    flags: flags,
    serialization: serialNone,
    compression: compressNone,
    sequence: actualSeq,
    payload: pcm,
  );
}

Uint8List _frame({
  required int messageType,
  required int flags,
  required int serialization,
  required int compression,
  required int sequence,
  required Uint8List payload,
}) {
  final hasSequence = (flags & 0x01) != 0 || (flags & 0x02) != 0;
  final headerLen = 4;
  final seqLen = hasSequence ? 4 : 0;
  final payloadSizeLen = 4;
  final total = headerLen + seqLen + payloadSizeLen + payload.length;

  final out = Uint8List(total);
  // header
  out[0] = 0x11; // proto v1, header = 4 bytes
  out[1] = ((messageType & 0x0F) << 4) | (flags & 0x0F);
  out[2] = ((serialization & 0x0F) << 4) | (compression & 0x0F);
  out[3] = 0x00;

  var off = 4;
  if (hasSequence) {
    final bd = ByteData.view(out.buffer, off, 4);
    bd.setInt32(0, sequence, Endian.big);
    off += 4;
  }
  // payload size
  ByteData.view(out.buffer, off, 4).setUint32(0, payload.length, Endian.big);
  off += 4;
  // payload
  out.setRange(off, off + payload.length, payload);
  return out;
}

class VolcengineFrame {
  final int messageType;
  final int flags;
  final int? sequence;
  final int? errorCode;
  final String? text; // recognised text from FULL_SERVER_RESPONSE
  final bool isFinal; // true when server marks utterance as definite
  final Map<String, dynamic>? rawJson;

  const VolcengineFrame({
    required this.messageType,
    required this.flags,
    this.sequence,
    this.errorCode,
    this.text,
    this.isFinal = false,
    this.rawJson,
  });
}

/// Parse one inbound frame. Tolerant to optional segments — flags determine
/// what's actually present.
VolcengineFrame parseFrame(Uint8List data) {
  if (data.length < 4) {
    throw 'volcengine: frame too short (${data.length} bytes)';
  }
  // final headerLen = (data[0] & 0x0F) * 4;  // for completeness; we use 4
  final messageType = (data[1] >> 4) & 0x0F;
  final flags = data[1] & 0x0F;
  final serialization = (data[2] >> 4) & 0x0F;

  var off = 4;
  int? seq;
  if ((flags & 0x01) != 0 || (flags & 0x02) != 0) {
    seq = ByteData.view(data.buffer, data.offsetInBytes + off, 4).getInt32(0, Endian.big);
    off += 4;
  }
  if ((flags & 0x04) != 0) {
    // event id, 4 bytes — skip; not needed for ASR
    off += 4;
  }
  if ((flags & 0x10) != 0) {
    final sessLen = ByteData.view(data.buffer, data.offsetInBytes + off, 4).getUint32(0, Endian.big);
    off += 4 + sessLen;
  }

  int? errorCode;
  if (messageType == msgErrorMessage) {
    errorCode = ByteData.view(data.buffer, data.offsetInBytes + off, 4).getUint32(0, Endian.big);
    off += 4;
  }

  final payloadSize = ByteData.view(data.buffer, data.offsetInBytes + off, 4).getUint32(0, Endian.big);
  off += 4;
  final payload = data.sublist(off, off + payloadSize);

  String? text;
  bool isFinal = false;
  Map<String, dynamic>? json;
  if (serialization == serialJSON && payload.isNotEmpty) {
    try {
      json = jsonDecode(utf8.decode(payload)) as Map<String, dynamic>;
      final result = json['result'];
      if (result is Map) {
        text = result['text']?.toString();
        // "is_final" can show up under result; also "definite": true sometimes
        isFinal = result['is_final'] == true || result['definite'] == true;
      }
      // alternative shape: top-level text
      text ??= json['text']?.toString();
      // negative sequence on inbound = server-confirmed final utterance
      if (seq != null && seq < 0) isFinal = true;
    } catch (_) {/* malformed; let caller see raw bytes */}
  }

  return VolcengineFrame(
    messageType: messageType,
    flags: flags,
    sequence: seq,
    errorCode: errorCode,
    text: text,
    isFinal: isFinal,
    rawJson: json,
  );
}
