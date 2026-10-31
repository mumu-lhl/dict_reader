import 'dart:typed_data';

import 'dict_reader_base.dart';
import 'dictionary_reader.dart';

/// Represents a record from an MDD file.
///
/// An MDD record typically contains a key (the word or phrase) and its
/// associated raw binary data.
class MddRecord {
  /// The key text associated with the record.
  final String keyText;

  /// The raw binary data of the record.
  final List<int> data;

  /// Creates a new [MddRecord] instance.
  const MddRecord(this.keyText, this.data);
}

/// Represents a record from an MDX file.
///
/// An MDX record typically contains a key (the word or phrase) and its
/// associated textual data (e.g., definition, explanation).
class MdxRecord {
  /// The key text associated with the record.
  final String keyText;

  /// The textual data of the record.
  final String data;

  /// Creates a new [MdxRecord] instance.
  const MdxRecord(this.keyText, this.data);
}

/// Represents offset information for a record within a dictionary file.
///
/// This class provides details necessary to locate and decompress a specific
/// record's data from the dictionary file, without needing to load the entire
/// record block into memory.
class RecordOffsetInfo {
  /// The key text associated with the record.
  final String keyText;

  /// The byte offset of the record block within the dictionary file.
  final int recordBlockOffset;

  /// The starting offset of the record's data within its decompressed record block.
  final int startOffset;

  /// The ending offset of the record's data within its decompressed record block.
  final int endOffset;

  /// The compressed size of the record block containing this record.
  final int compressedSize;

  /// All record block segments containing this record.
  ///
  /// This is empty for instances created with the original constructor shape.
  /// When a record spans multiple blocks, the segments are needed by
  /// [DictReader.readOneMdx] and [DictReader.readOneMdd] to reconstruct the complete record.
  final List<(int, int, int, int)> segments;

  /// Creates a new [RecordOffsetInfo] instance.
  const RecordOffsetInfo(
    this.keyText,
    this.recordBlockOffset,
    this.startOffset,
    this.endOffset,
    this.compressedSize, {
    this.segments = const [],
  });
}

/// A single MDX/MDD dictionary entry implementing [DictArticle].
class MdxEntry implements DictArticle {
  final RecordOffsetInfo offsetInfo;
  final DictReader reader;

  const MdxEntry({required this.offsetInfo, required this.reader});

  @override
  String get headword => offsetInfo.keyText;

  @override
  String get mimeType =>
      reader.isMdx ? 'text/html' : 'application/octet-stream';

  @override
  String get format => reader.isMdx ? 'mdx' : 'mdd';

  @override
  dynamic get raw => offsetInfo;

  @override
  Future<String> readText() => reader.readOneMdx(offsetInfo);

  @override
  Future<Uint8List> readData() async =>
      Uint8List.fromList(await reader.readRecordData(offsetInfo));

  @override
  Future<Stream<List<int>>> openRead({int? start, int? end}) async {
    final bytes = await readData();
    final length = bytes.length;
    final s = (start ?? 0).clamp(0, length);
    final e = (end ?? length).clamp(s, length);
    if (s >= e) return Stream.value(Uint8List(0));
    return Stream.value(Uint8List.sublistView(bytes, s, e));
  }

  @override
  String toString() => 'MdxEntry($headword, format: $format)';
}
