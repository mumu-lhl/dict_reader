import 'dart:convert';
import 'dart:typed_data';

import 'normalize.dart';

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
///   version          u32      2
///   collation        u32      1 = UTF-8 byte order (see below)
///   normalization    u32      1 = NFC (see normalize.dart)
///   unicodeVersion   u32      Unicode tables used to normalise, major*100+minor
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
///   entryCount * { keyLength u32, key bytes,
///                  [rawLength u32, raw bytes,]     only when the headword
///                                                  differs from the key
///                  recordStart u64, recordEnd u64 }
/// ```
///
/// Entries are sorted by collation. `recordEnd` is precomputed at build
/// time from the file-order successor (or `totalDecompressedSize` for the
/// last file-order entry), so lookup never needs the file-order key list.
///
/// Collation: UTF-8 byte order of the **normalised** key. For well-formed
/// strings this equals code-point order; it is NOT identical to Dart's
/// `String.compareTo` (UTF-16 code-unit order) when astral characters mix
/// with BMP characters in U+E000..U+FFFF — in that corner the byte order
/// wins, and suggestion order for such prefixes may differ from the old
/// in-memory sort. Lookup results (which entries match) are unaffected.
///
/// Normalisation: headwords are stored as Unicode NFC (see [normalizeKey]),
/// because authors are not consistent — the same visible word may be `é`
/// (U+00E9) or `e` + U+0301. The top bit of `keyLength` marks an entry whose
/// original spelling differs from the normalised key; that raw spelling is
/// stored right after the key and is what callers hand back to the UI. The
/// index stays cheap because the vast majority of headwords are already
/// normalised (CJK dictionaries: effectively all of them).
///
/// Keys are stored as the UTF-8 re-encoding of the decoded headword:
/// dictionaries in UTF-16 or legacy encodings are decoded first, and
/// malformed byte sequences are dropped by the tolerant decoder before
/// re-encoding, so a stored key is always valid UTF-8.
///
/// The MDX-embedded block order is never trusted: builders disagree on
/// it (notably for German/Greek), so the index is always self-sorted.
const cidxVersion = 2;

/// Collation id for UTF-8 byte order, the only collation this format has.
const cidxCollationUtf8ByteOrder = 1;

/// Top bit of the `keyLength` word: the entry carries a raw headword that
/// differs from its normalised key.
const _cidxHasRawKey = 0x80000000;

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

  /// Normalisation algorithm applied to the keys (see [normalizationNfc]).
  final int normalization;

  /// Unicode tables used to normalise the keys, `major * 100 + minor`.
  final int unicodeVersion;

  const CidxHeader({
    required this.filePath,
    required this.fileSize,
    required this.fileModified,
    required this.entryCount,
    required this.recordBlockOffset,
    required this.numberWidth,
    required this.totalDecompressedSize,
    required this.recordBlockInfoList,
    required this.normalization,
    required this.unicodeVersion,
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

/// Where one normalised entry lives inside the `.cidx` body.
class CidxEntryLayout {
  /// Byte range of the normalised key.
  final int keyOffset;
  final int keyLength;

  /// Byte range of the original spelling, or `null` when it equals the key.
  final int? rawOffset;
  final int? rawLength;

  final int recordStart;
  final int recordEnd;

  const CidxEntryLayout({
    required this.keyOffset,
    required this.keyLength,
    required this.rawOffset,
    required this.rawLength,
    required this.recordStart,
    required this.recordEnd,
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
/// [keyList] is in file order. Each headword is normalised with
/// [normalizeKey]; entries are sorted here by the UTF-8 byte order of the
/// normalised key (ties keep file order), so the build must not reuse a
/// `String.compareTo` sort — the two orders disagree for astral characters
/// mixed with BMP characters in U+E000..U+FFFF.
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
  final keyBytes = <Uint8List>[];
  final rawBytes = <Uint8List?>[];
  for (final entry in keyList) {
    final raw = entry.$2;
    final normalized = normalizeKey(raw);
    keyBytes.add(Uint8List.fromList(utf8.encode(normalized)));
    // Compare by value, not identity: `normalizeKey` returns a fresh string
    // for every non-ASCII key, even when it was already NFC, and storing a
    // duplicate of those would roughly double the key section of every
    // Japanese, Korean or Vietnamese dictionary.
    rawBytes.add(
      normalized == raw ? null : Uint8List.fromList(utf8.encode(raw)),
    );
  }

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
  // normalization(4) + unicodeVersion(4) + pathLength(4) + fileSize(8) +
  // fileModified(8) + entryCount(8) + recordBlockOffset(8) +
  // numberWidth(4) + totalDecompressedSize(8) + blockCount(4).
  final headerSize =
      4 + 4 + 4 + 4 + 4 + 4 + pathBytes.length + 8 + 8 + 8 + 8 + 4 + 8 + 4;
  final blockTableSize = blocks.length * 16;
  final offsetTableSize = keyList.length * 8;
  var bodySize = 0;
  for (var i = 0; i < keyBytes.length; i++) {
    bodySize += 4 + keyBytes[i].length + 16;
    final raw = rawBytes[i];
    if (raw != null) bodySize += 4 + raw.length;
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
  _writeU32(data, pos, normalizationNfc);
  pos += 4;
  _writeU32(data, pos, normalizationUnicodeVersion);
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
    final raw = rawBytes[physical];
    final recordStart = keyList[physical].$1;
    final recordEnd = physical + 1 < keyList.length
        ? keyList[physical + 1].$1
        : totalDecompressedSize;
    final entryPos = bodyStart + bodyPos;
    _writeU32(
      data,
      entryPos,
      bytes.length | (raw != null ? _cidxHasRawKey : 0),
    );
    var cursor = entryPos + 4;
    out.setRange(cursor, cursor + bytes.length, bytes);
    cursor += bytes.length;
    if (raw != null) {
      _writeU32(data, cursor, raw.length);
      cursor += 4;
      out.setRange(cursor, cursor + raw.length, raw);
      cursor += raw.length;
    }
    _writeU64(data, cursor, recordStart);
    _writeU64(data, cursor + 8, recordEnd);
    bodyPos += cursor + 16 - entryPos;
  }
  return out;
}

/// Parses and fully validates a `.cidx` file: magic, version, collation,
/// normalisation metadata, and a linear walk over every entry (offsets
/// monotonic, body exactly consumed). Throws [FormatException] on any
/// inconsistency, including an index built with a different normalisation
/// algorithm or Unicode table version — callers rebuild in that case.
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
  final normalization = u32();
  if (normalization != normalizationNfc) {
    throw const FormatException('Unsupported .cidx normalization');
  }
  final unicodeVersion = u32();
  if (unicodeVersion != normalizationUnicodeVersion) {
    throw const FormatException('Stale .cidx Unicode tables');
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
    final keyLengthWord =
        ByteData.sublistView(body).getUint32(expected, Endian.big);
    final keyLength = keyLengthWord & 0x7FFFFFFF;
    expected += 4 + keyLength;
    if (keyLengthWord & _cidxHasRawKey != 0) {
      if (expected + 4 > body.length) {
        throw const FormatException('Truncated .cidx body');
      }
      final rawLength =
          ByteData.sublistView(body).getUint32(expected, Endian.big);
      expected += 4 + rawLength;
    }
    expected += 16;
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
      normalization: normalization,
      unicodeVersion: unicodeVersion,
    ),
    entryOffsets: offsets,
    body: body,
  );
}

/// Reads the layout of the [sortedIndex]-th entry of a parsed body.
CidxEntryLayout cidxEntryAt(Uint8List body, int sortedIndex, int entryStart) {
  final data = ByteData.sublistView(body);
  final keyLengthWord = data.getUint32(entryStart, Endian.big);
  final keyLength = keyLengthWord & 0x7FFFFFFF;
  final keyOffset = entryStart + 4;
  var cursor = keyOffset + keyLength;
  int? rawOffset;
  int? rawLength;
  if (keyLengthWord & _cidxHasRawKey != 0) {
    rawLength = data.getUint32(cursor, Endian.big);
    rawOffset = cursor + 4;
    cursor = rawOffset + rawLength;
  }
  final recordStart = data.getUint64(cursor, Endian.big);
  final recordEnd = data.getUint64(cursor + 8, Endian.big);
  return CidxEntryLayout(
    keyOffset: keyOffset,
    keyLength: keyLength,
    rawOffset: rawOffset,
    rawLength: rawLength,
    recordStart: recordStart,
    recordEnd: recordEnd,
  );
}
