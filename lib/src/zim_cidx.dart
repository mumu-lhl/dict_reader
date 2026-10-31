import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'normalize.dart';

const int zimCidxMagic = 0x005A4944; // \0ZID
const int zimCidxVersion = 1;

/// Serializes the parsed index of [reader] into a fast-loading binary `.cidx` buffer.
Uint8List serializeZimCidx({
  required String filePath,
  required int fileSize,
  required int fileModified,
  required int majorVersion,
  required int minorVersion,
  required Uint8List uuid,
  required int entryCount,
  required int clusterCount,
  required int pathPtrPos,
  required int titlePtrPos,
  required int clusterPtrPos,
  required int mimeListPos,
  required int mainPage,
  required int layoutPage,
  required int checksumPos,
  required List<String> mimeTypes,
  required Map<String, String> metadata,
  required Uint64List clusterOffsets,
  required Uint64List pathPointers,
  required Uint32List? titlePointers,
  required List<int> articleIndices,
  required List<String> articleTitles,
  required List<int> searchOrder,
  required Map<String, int> pathToEntryIndex,
}) {
  final bb = BytesBuilder(copy: false);

  // Magic & Version
  final hBd = ByteData(8);
  hBd.setUint32(0, zimCidxMagic, Endian.big);
  hBd.setUint32(4, zimCidxVersion, Endian.big);
  bb.add(hBd.buffer.asUint8List());

  // Unicode table version
  final uBd = ByteData(4);
  uBd.setUint32(0, normalizationUnicodeVersion, Endian.big);
  bb.add(uBd.buffer.asUint8List());

  // File identification
  final pathBytes = utf8.encode(filePath);
  final fStatBd = ByteData(2 + pathBytes.length + 8 + 8);
  var fPos = 0;
  fStatBd.setUint16(fPos, pathBytes.length, Endian.big);
  fPos += 2;
  for (var i = 0; i < pathBytes.length; i++) {
    fStatBd.setUint8(fPos++, pathBytes[i]);
  }
  fStatBd.setInt64(fPos, fileSize, Endian.big);
  fPos += 8;
  fStatBd.setInt64(fPos, fileModified, Endian.big);
  fPos += 8;
  bb.add(fStatBd.buffer.asUint8List());

  // ZIM Header fields
  final zHeaderBd = ByteData(76);
  var zPos = 0;
  zHeaderBd.setUint16(zPos, majorVersion, Endian.big);
  zPos += 2;
  zHeaderBd.setUint16(zPos, minorVersion, Endian.big);
  zPos += 2;
  for (var i = 0; i < 16; i++) {
    zHeaderBd.setUint8(zPos++, i < uuid.length ? uuid[i] : 0);
  }
  zHeaderBd.setUint32(zPos, entryCount, Endian.big);
  zPos += 4;
  zHeaderBd.setUint32(zPos, clusterCount, Endian.big);
  zPos += 4;
  zHeaderBd.setUint64(zPos, pathPtrPos, Endian.big);
  zPos += 8;
  zHeaderBd.setUint64(zPos, titlePtrPos, Endian.big);
  zPos += 8;
  zHeaderBd.setUint64(zPos, clusterPtrPos, Endian.big);
  zPos += 8;
  zHeaderBd.setUint64(zPos, mimeListPos, Endian.big);
  zPos += 8;
  zHeaderBd.setUint32(zPos, mainPage, Endian.big);
  zPos += 4;
  zHeaderBd.setUint32(zPos, layoutPage, Endian.big);
  zPos += 4;
  zHeaderBd.setUint64(zPos, checksumPos, Endian.big);
  zPos += 8;
  bb.add(zHeaderBd.buffer.asUint8List());

  // Cluster Offsets
  final cOffBd = ByteData(clusterOffsets.length * 8);
  for (var i = 0; i < clusterOffsets.length; i++) {
    cOffBd.setUint64(i * 8, clusterOffsets[i], Endian.big);
  }
  bb.add(cOffBd.buffer.asUint8List());

  // Path Pointers
  final pPtrBd = ByteData(pathPointers.length * 8);
  for (var i = 0; i < pathPointers.length; i++) {
    pPtrBd.setUint64(i * 8, pathPointers[i], Endian.big);
  }
  bb.add(pPtrBd.buffer.asUint8List());

  // Title Pointers
  final hasTitle = titlePointers != null && titlePointers.isNotEmpty;
  final tFlag = ByteData(1);
  tFlag.setUint8(0, hasTitle ? 1 : 0);
  bb.add(tFlag.buffer.asUint8List());
  if (hasTitle) {
    final tPtrBd = ByteData(titlePointers.length * 4);
    for (var i = 0; i < titlePointers.length; i++) {
      tPtrBd.setUint32(i * 4, titlePointers[i], Endian.big);
    }
    bb.add(tPtrBd.buffer.asUint8List());
  }

  // MIME Types
  final mimeCountBd = ByteData(4);
  mimeCountBd.setUint32(0, mimeTypes.length, Endian.big);
  bb.add(mimeCountBd.buffer.asUint8List());
  for (final m in mimeTypes) {
    final mBytes = utf8.encode(m);
    final mLenBd = ByteData(2);
    mLenBd.setUint16(0, mBytes.length, Endian.big);
    bb.add(mLenBd.buffer.asUint8List());
    bb.add(mBytes);
  }

  // Metadata
  final metaCountBd = ByteData(4);
  metaCountBd.setUint32(0, metadata.length, Endian.big);
  bb.add(metaCountBd.buffer.asUint8List());
  for (final e in metadata.entries) {
    final kBytes = utf8.encode(e.key);
    final vBytes = utf8.encode(e.value);
    final kvLenBd = ByteData(4);
    kvLenBd.setUint16(0, kBytes.length, Endian.big);
    kvLenBd.setUint16(2, vBytes.length, Endian.big);
    bb.add(kvLenBd.buffer.asUint8List());
    bb.add(kBytes);
    bb.add(vBytes);
  }

  // Article Indices
  final artIdxBd = ByteData(4 + articleIndices.length * 4);
  artIdxBd.setUint32(0, articleIndices.length, Endian.big);
  for (var i = 0; i < articleIndices.length; i++) {
    artIdxBd.setUint32(4 + i * 4, articleIndices[i], Endian.big);
  }
  bb.add(artIdxBd.buffer.asUint8List());

  // Article Titles
  final artTitlesCountBd = ByteData(4);
  artTitlesCountBd.setUint32(0, articleTitles.length, Endian.big);
  bb.add(artTitlesCountBd.buffer.asUint8List());
  for (final t in articleTitles) {
    final tBytes = utf8.encode(t);
    final tLenBd = ByteData(2);
    tLenBd.setUint16(0, tBytes.length, Endian.big);
    bb.add(tLenBd.buffer.asUint8List());
    bb.add(tBytes);
  }

  // Search Order
  final sOrderBd = ByteData(4 + searchOrder.length * 4);
  sOrderBd.setUint32(0, searchOrder.length, Endian.big);
  for (var i = 0; i < searchOrder.length; i++) {
    sOrderBd.setUint32(4 + i * 4, searchOrder[i], Endian.big);
  }
  bb.add(sOrderBd.buffer.asUint8List());

  // Path to Entry Index
  final pathMapCountBd = ByteData(4);
  pathMapCountBd.setUint32(0, pathToEntryIndex.length, Endian.big);
  bb.add(pathMapCountBd.buffer.asUint8List());
  for (final e in pathToEntryIndex.entries) {
    final pBytes = utf8.encode(e.key);
    final pEntryBd = ByteData(2 + 4);
    pEntryBd.setUint16(0, pBytes.length, Endian.big);
    pEntryBd.setUint32(2, e.value, Endian.big);
    bb.add(pEntryBd.buffer.asUint8List());
    bb.add(pBytes);
  }

  return bb.toBytes();
}

/// Result of deserializing a ZIM `.cidx` buffer.
class DeserializedZimCidx {
  final int majorVersion;
  final int minorVersion;
  final Uint8List uuid;
  final int entryCount;
  final int clusterCount;
  final int pathPtrPos;
  final int titlePtrPos;
  final int clusterPtrPos;
  final int mimeListPos;
  final int mainPage;
  final int layoutPage;
  final int checksumPos;
  final List<String> mimeTypes;
  final Map<String, String> metadata;
  final Uint64List clusterOffsets;
  final Uint64List pathPointers;
  final Uint32List? titlePointers;
  final List<int> articleIndices;
  final List<String> articleTitles;
  final List<int> searchOrder;
  final Map<String, int> pathToEntryIndex;

  DeserializedZimCidx({
    required this.majorVersion,
    required this.minorVersion,
    required this.uuid,
    required this.entryCount,
    required this.clusterCount,
    required this.pathPtrPos,
    required this.titlePtrPos,
    required this.clusterPtrPos,
    required this.mimeListPos,
    required this.mainPage,
    required this.layoutPage,
    required this.checksumPos,
    required this.mimeTypes,
    required this.metadata,
    required this.clusterOffsets,
    required this.pathPointers,
    required this.titlePointers,
    required this.articleIndices,
    required this.articleTitles,
    required this.searchOrder,
    required this.pathToEntryIndex,
  });
}

/// Parses and validates a ZIM `.cidx` buffer against the file on disk.
DeserializedZimCidx deserializeZimCidx(Uint8List bytes, File targetFile) {
  if (bytes.length < 80) {
    throw const FormatException('Truncated ZIM .cidx file');
  }

  final bd = ByteData.sublistView(bytes);
  var pos = 0;

  final magic = bd.getUint32(pos, Endian.big);
  pos += 4;
  if (magic != zimCidxMagic) {
    throw const FormatException('Not a ZIM .cidx file: invalid magic number');
  }

  final version = bd.getUint32(pos, Endian.big);
  pos += 4;
  if (version != zimCidxVersion) {
    throw const FormatException('Unsupported ZIM .cidx version');
  }

  final tableVersion = bd.getUint32(pos, Endian.big);
  pos += 4;
  if (tableVersion != normalizationUnicodeVersion) {
    throw const FormatException(
        'Stale ZIM .cidx: Unicode table version mismatch');
  }

  final pathLen = bd.getUint16(pos, Endian.big);
  pos += 2;
  // final path = utf8.decode(bytes.sublist(pos, pos + pathLen));
  pos += pathLen;

  final expectedSize = bd.getInt64(pos, Endian.big);
  pos += 8;
  final expectedModified = bd.getInt64(pos, Endian.big);
  pos += 8;

  final stat = targetFile.statSync();
  if (stat.size != expectedSize ||
      stat.modified.microsecondsSinceEpoch != expectedModified) {
    throw const FormatException(
        'Stale ZIM .cidx: file size or timestamp mismatch');
  }

  final majorVersion = bd.getUint16(pos, Endian.big);
  pos += 2;
  final minorVersion = bd.getUint16(pos, Endian.big);
  pos += 2;
  if (majorVersion < 6) {
    throw const FormatException(
      'Stale ZIM .cidx: unsupported ZIM version (only 6.x)',
    );
  }
  final uuid = Uint8List.fromList(bytes.sublist(pos, pos + 16));
  pos += 16;
  final entryCount = bd.getUint32(pos, Endian.big);
  pos += 4;
  final clusterCount = bd.getUint32(pos, Endian.big);
  pos += 4;
  final pathPtrPos = bd.getUint64(pos, Endian.big);
  pos += 8;
  final titlePtrPos = bd.getUint64(pos, Endian.big);
  pos += 8;
  final clusterPtrPos = bd.getUint64(pos, Endian.big);
  pos += 8;
  final mimeListPos = bd.getUint64(pos, Endian.big);
  pos += 8;
  final mainPage = bd.getUint32(pos, Endian.big);
  pos += 4;
  final layoutPage = bd.getUint32(pos, Endian.big);
  pos += 4;
  final checksumPos = bd.getUint64(pos, Endian.big);
  pos += 8;

  final clusterOffsets = Uint64List(clusterCount);
  for (var i = 0; i < clusterCount; i++) {
    clusterOffsets[i] = bd.getUint64(pos, Endian.big);
    pos += 8;
  }

  final pathPointers = Uint64List(entryCount);
  for (var i = 0; i < entryCount; i++) {
    pathPointers[i] = bd.getUint64(pos, Endian.big);
    pos += 8;
  }

  final hasTitle = bd.getUint8(pos) == 1;
  pos += 1;
  Uint32List? titlePointers;
  if (hasTitle) {
    titlePointers = Uint32List(entryCount);
    for (var i = 0; i < entryCount; i++) {
      titlePointers[i] = bd.getUint32(pos, Endian.big);
      pos += 4;
    }
  }

  final mimeCount = bd.getUint32(pos, Endian.big);
  pos += 4;
  final mimeTypes = <String>[];
  for (var i = 0; i < mimeCount; i++) {
    final mLen = bd.getUint16(pos, Endian.big);
    pos += 2;
    mimeTypes.add(utf8.decode(bytes.sublist(pos, pos + mLen)));
    pos += mLen;
  }

  final metaCount = bd.getUint32(pos, Endian.big);
  pos += 4;
  final metadata = <String, String>{};
  for (var i = 0; i < metaCount; i++) {
    final kLen = bd.getUint16(pos, Endian.big);
    final vLen = bd.getUint16(pos + 2, Endian.big);
    pos += 4;
    final k = utf8.decode(bytes.sublist(pos, pos + kLen));
    pos += kLen;
    final v = utf8.decode(bytes.sublist(pos, pos + vLen));
    pos += vLen;
    metadata[k] = v;
  }

  final artCount = bd.getUint32(pos, Endian.big);
  pos += 4;
  final articleIndices = List<int>.filled(artCount, 0);
  for (var i = 0; i < artCount; i++) {
    articleIndices[i] = bd.getUint32(pos, Endian.big);
    pos += 4;
  }

  final artTitlesCount = bd.getUint32(pos, Endian.big);
  pos += 4;
  final articleTitles = <String>[];
  for (var i = 0; i < artTitlesCount; i++) {
    final tLen = bd.getUint16(pos, Endian.big);
    pos += 2;
    articleTitles.add(utf8.decode(bytes.sublist(pos, pos + tLen)));
    pos += tLen;
  }

  final searchOrderCount = bd.getUint32(pos, Endian.big);
  pos += 4;
  final searchOrder = List<int>.filled(searchOrderCount, 0);
  for (var i = 0; i < searchOrderCount; i++) {
    searchOrder[i] = bd.getUint32(pos, Endian.big);
    pos += 4;
  }

  final pathMapCount = bd.getUint32(pos, Endian.big);
  pos += 4;
  final pathToEntryIndex = <String, int>{};
  for (var i = 0; i < pathMapCount; i++) {
    final pLen = bd.getUint16(pos, Endian.big);
    final idx = bd.getUint32(pos + 2, Endian.big);
    pos += 6;
    final p = utf8.decode(bytes.sublist(pos, pos + pLen));
    pos += pLen;
    pathToEntryIndex[p] = idx;
  }

  return DeserializedZimCidx(
    majorVersion: majorVersion,
    minorVersion: minorVersion,
    uuid: uuid,
    entryCount: entryCount,
    clusterCount: clusterCount,
    pathPtrPos: pathPtrPos,
    titlePtrPos: titlePtrPos,
    clusterPtrPos: clusterPtrPos,
    mimeListPos: mimeListPos,
    mainPage: mainPage,
    layoutPage: layoutPage,
    checksumPos: checksumPos,
    mimeTypes: mimeTypes,
    metadata: metadata,
    clusterOffsets: clusterOffsets,
    pathPointers: pathPointers,
    titlePointers: titlePointers,
    articleIndices: articleIndices,
    articleTitles: articleTitles,
    searchOrder: searchOrder,
    pathToEntryIndex: pathToEntryIndex,
  );
}
