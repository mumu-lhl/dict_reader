import 'dart:convert';
import 'dart:typed_data';

/// Compact on-disk binary index (`.cidx`) for MDX/MDD dictionaries.
///
/// This replaces the old JSON cache outright: one format only, no fallback.
/// The index is rebuilt from the dictionary file whenever the dictionary
/// itself changes (same path/size/mtime validation as the old cache), so
/// it keeps the cache directory's rebuildable semantics.
///
/// Layout (all integers big-endian):
///
/// ```text
/// header:
///   magic            4 bytes  "CDIX"
///   version          u32      1
///   collation        u32      1 = UTF-8 byte order (see below)
///   pathLength       u32
///   path             bytes    resolved dictionary path (UTF-8)
///   fileSize         u64
///   fileModified     u64      microseconds since epoch
///   entryCount       u64
///   recordBlockOffset u64
///   numberWidth      u32
///   totalDecompressedSize u64
///   blockCount       u32
///   block table      blockCount * (compressedSize u64, decompressedSize u64)
/// offset table:
///   entryCount * u64 offsets, one per entry, relative to the body start.
///   Entries are variable-length, so random access during binary search
///   goes through this table; it is the index into the sorted array,
///   not a second copy of the data.
/// body:
///   entryCount * { keyLength u32, key bytes, recordStart u64, recordEnd u64 }
/// ```
///
/// Entries are sorted by collation. `recordEnd` is precomputed at build
/// time from the file-order successor (or `totalDecompressedSize` for the
/// last file-order entry), so lookup never needs the file-order key list.
///
/// Collation: UTF-8 byte order. For well-formed strings this equals
/// code-point order; it is NOT identical to Dart's `String.compareTo`
/// (UTF-16 code-unit order) when astral characters mix with BMP
/// characters in U+E000..U+FFFF — in that corner the byte order wins,
/// and suggestion order for such prefixes may differ from the old
/// in-memory sort. Lookup results (which entries match) are unaffected.
/// Keys are stored as the UTF-8 re-encoding of the decoded headword:
/// dictionaries in UTF-16 or legacy encodings are decoded first, and
/// malformed byte sequences are dropped by the tolerant decoder before
/// re-encoding, so a stored key is always valid UTF-8. A malformed
/// headword was never findable under its raw bytes anyway.
///
/// The MDX-embedded block order is never trusted: builders disagree on
/// it (notably for German/Greek), so the index is always self-sorted.
const cidxVersion = 1;

/// Collation id for UTF-8 byte order, the only collation this format has.
const cidxCollationUtf8ByteOrder = 1;

/// Header fields of a `.cidx` file, as parsed by [parseCidx].
class CidxHeader {
  final String filePath;
  final int fileSize;
  final int fileModified;
  final int entryCount;
  final int recordBlockOffset;
  final int numberWidth;
  final int totalDecompressedSize;
  final List<(int, int)> recordBlockInfoList;

  const CidxHeader({
    required this.filePath,
    required this.fileSize,
    required this.fileModified,
    required this.entryCount,
    required this.recordBlockOffset,
    required this.numberWidth,
    required this.totalDecompressedSize,
    required this.recordBlockInfoList,
  });
}

/// A parsed `.cidx` file: its header, the entry offset table, and a view
/// of the entry body (no copy of the body is made).
class CidxData {
  final CidxHeader header;
  final List<int> entryOffsets;
  final Uint8List body;

  const CidxData({
    required this.header,
    required this.entryOffsets,
    required this.body,
  });
}

/// Lexicographic comparison of unsigned bytes: `a[aOffset .. aOffset +
/// aLength)` against `b[bOffset .. bOffset + bLength)`. A strict prefix
/// sorts first, like `memcmp`.
int compareBytes(
  List<int> a,
  int aOffset,
  int aLength,
  List<int> b, [
  int bOffset = 0,
  int? bLength,
]) {
  final bl = bLength ?? b.length - bOffset;
  final n = aLength < bl ? aLength : bl;
  for (var i = 0; i < n; i++) {
    final diff = a[aOffset + i] - b[bOffset + i];
    if (diff != 0) return diff;
  }
  return aLength - bl;
}

/// Whether `a[aOffset .. aOffset + aLength)` starts with [prefix].
bool startsWithBytes(
  List<int> a,
  int aOffset,
  int aLength,
  List<int> prefix,
) {
  if (aLength < prefix.length) return false;
  for (var i = 0; i < prefix.length; i++) {
    if (a[aOffset + i] != prefix[i]) return false;
  }
  return true;
}

void _writeU32(ByteData data, int offset, int value) {
  data.setUint32(offset, value, Endian.big);
}

void _writeU64(ByteData data, int offset, int value) {
  data.setUint64(offset, value, Endian.big);
}

/// Builds a `.cidx` file from a scanned dictionary.
///
/// [keyList] is in file order; entries are sorted here by UTF-8 byte
/// order (ties keep file order), so the build must not reuse a
/// `String.compareTo` sort — the two orders disagree for astral
/// characters mixed with BMP characters in U+E000..U+FFFF.
Uint8List buildCidx({
  required List<(int, String)> keyList,
  required List<(int, int)>? recordBlockInfoList,
  required int recordBlockOffset,
  required int numberWidth,
  required int totalDecompressedSize,
  required String filePath,
  required int fileSize,
  required int fileModified,
}) {
  final blocks = recordBlockInfoList ?? const <(int, int)>[];
  final keyBytes = <Uint8List>[
    for (final entry in keyList) Uint8List.fromList(utf8.encode(entry.$2)),
  ];
  final order = List<int>.generate(keyList.length, (i) => i)
    ..sort((a, b) {
      final comparison = compareBytes(
        keyBytes[a],
        0,
        keyBytes[a].length,
        keyBytes[b],
      );
      return comparison != 0 ? comparison : a.compareTo(b);
    });

  final pathBytes = utf8.encode(filePath);
  // Fixed header fields: magic(4) + version(4) + collation(4) +
  // pathLength(4) + fileSize(8) + fileModified(8) + entryCount(8) +
  // recordBlockOffset(8) + numberWidth(4) + totalDecompressedSize(8) +
  // blockCount(4).
  final headerSize =
      4 + 4 + 4 + 4 + pathBytes.length + 8 + 8 + 8 + 8 + 4 + 8 + 4;
  final blockTableSize = blocks.length * 16;
  final offsetTableSize = keyList.length * 8;
  var bodySize = 0;
  for (final bytes in keyBytes) {
    bodySize += 4 + bytes.length + 16;
  }

  final out =
      Uint8List(headerSize + blockTableSize + offsetTableSize + bodySize);
  final data = ByteData.sublistView(out);
  var pos = 0;
  out.setRange(pos, pos + 4, [0x43, 0x44, 0x49, 0x58]); // "CDIX"
  pos += 4;
  _writeU32(data, pos, cidxVersion);
  pos += 4;
  _writeU32(data, pos, cidxCollationUtf8ByteOrder);
  pos += 4;
  _writeU32(data, pos, pathBytes.length);
  pos += 4;
  out.setRange(pos, pos + pathBytes.length, pathBytes);
  pos += pathBytes.length;
  _writeU64(data, pos, fileSize);
  pos += 8;
  _writeU64(data, pos, fileModified);
  pos += 8;
  _writeU64(data, pos, keyList.length);
  pos += 8;
  _writeU64(data, pos, recordBlockOffset);
  pos += 8;
  _writeU32(data, pos, numberWidth);
  pos += 4;
  _writeU64(data, pos, totalDecompressedSize);
  pos += 8;
  _writeU32(data, pos, blocks.length);
  pos += 4;
  for (final block in blocks) {
    _writeU64(data, pos, block.$1);
    pos += 8;
    _writeU64(data, pos, block.$2);
    pos += 8;
  }

  // Offset table first, so entry offsets are relative to a body start
  // known before the body is written.
  final bodyStart = pos + offsetTableSize;
  var bodyPos = 0;
  for (var i = 0; i < order.length; i++) {
    _writeU64(data, pos, bodyPos);
    pos += 8;
    final physical = order[i];
    final bytes = keyBytes[physical];
    final recordStart = keyList[physical].$1;
    final recordEnd = physical + 1 < keyList.length
        ? keyList[physical + 1].$1
        : totalDecompressedSize;
    final entryPos = bodyStart + bodyPos;
    _writeU32(data, entryPos, bytes.length);
    out.setRange(entryPos + 4, entryPos + 4 + bytes.length, bytes);
    _writeU64(data, entryPos + 4 + bytes.length, recordStart);
    _writeU64(data, entryPos + 4 + bytes.length + 8, recordEnd);
    bodyPos += 4 + bytes.length + 16;
  }
  return out;
}

/// Parses and fully validates a `.cidx` file: magic, version, collation,
/// and a linear walk over every entry (offsets monotonic, body exactly
/// consumed). Throws [FormatException] on any inconsistency.
CidxData parseCidx(Uint8List bytes) {
  final data = ByteData.sublistView(bytes);
  var pos = 0;

  int need(int count) {
    if (pos + count > bytes.length) {
      throw const FormatException('Truncated .cidx file');
    }
    final value = pos;
    pos += count;
    return value;
  }

  int u32() => data.getUint32(need(4), Endian.big);
  int u64() => data.getUint64(need(8), Endian.big);

  if (bytes.length < 4 ||
      bytes[0] != 0x43 ||
      bytes[1] != 0x44 ||
      bytes[2] != 0x49 ||
      bytes[3] != 0x58) {
    throw const FormatException('Not a .cidx file');
  }
  pos = 4;
  if (u32() != cidxVersion) {
    throw const FormatException('Unsupported .cidx version');
  }
  if (u32() != cidxCollationUtf8ByteOrder) {
    throw const FormatException('Unsupported .cidx collation');
  }
  final pathLength = u32();
  final pathStart = need(pathLength);
  final filePath = utf8.decode(
    Uint8List.sublistView(bytes, pathStart, pathStart + pathLength),
  );
  final fileSize = u64();
  final fileModified = u64();
  final entryCount = u64();
  final recordBlockOffset = u64();
  final numberWidth = u32();
  final totalDecompressedSize = u64();
  final blockCount = u32();
  final blocks = <(int, int)>[];
  for (var i = 0; i < blockCount; i++) {
    blocks.add((u64(), u64()));
  }
  final offsets = <int>[];
  for (var i = 0; i < entryCount; i++) {
    offsets.add(u64());
  }
  final body = Uint8List.sublistView(bytes, pos);
  // Walk every entry: offsets must be monotonic and the body must be
  // exactly consumed, so a truncated or corrupt file fails here rather
  // than at lookup time.
  var expected = 0;
  for (var i = 0; i < entryCount; i++) {
    if (offsets[i] != expected) {
      throw const FormatException('.cidx entry offsets are not contiguous');
    }
    if (expected + 4 > body.length) {
      throw const FormatException('Truncated .cidx body');
    }
    final keyLength =
        ByteData.sublistView(body).getUint32(expected, Endian.big);
    expected += 4 + keyLength + 16;
    if (expected > body.length) {
      throw const FormatException('Truncated .cidx body');
    }
  }
  if (expected != body.length) {
    throw const FormatException('.cidx body has trailing bytes');
  }

  return CidxData(
    header: CidxHeader(
      filePath: filePath,
      fileSize: fileSize,
      fileModified: fileModified,
      entryCount: entryCount,
      recordBlockOffset: recordBlockOffset,
      numberWidth: numberWidth,
      totalDecompressedSize: totalDecompressedSize,
      recordBlockInfoList: blocks,
    ),
    entryOffsets: offsets,
    body: body,
  );
}
