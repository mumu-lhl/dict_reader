import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'cidx.dart';
import 'dictionary_reader.dart';
import 'normalize.dart';

/// One typed field inside a StarDict entry.
///
/// The [type] is the single-character type code from the dictionary's
/// `sametypesequence` (or the per-field marker when the dictionary does not
/// declare one). Text fields carry decoded [text]; binary fields (uppercase
/// type codes such as `W` or `P`) carry raw [data] instead.
class StarDictField {
  final String type;
  final String? text;
  final Uint8List? data;

  const StarDictField(this.type, {this.text, this.data});

  bool get isText => text != null;

  @override
  String toString() => 'StarDictField($type, ${isText ? 'text' : 'binary'})';
}

/// A single dictionary entry: the headword plus its typed fields, in the
/// order they appear in the `.dict` data.
class StarDictEntry implements DictArticle {
  @override
  final String headword;
  final List<StarDictField> fields;

  const StarDictEntry({required this.headword, required this.fields});

  @override
  String get format => 'stardict';

  @override
  dynamic get raw => this;

  @override
  String get mimeType =>
      fields.any((f) => f.type == 'h') ? 'text/html' : 'text/plain';

  /// Combined text content of all text fields in this entry.
  String get content {
    final sb = StringBuffer();
    for (final f in fields) {
      if (f.text != null) {
        if (sb.isNotEmpty) sb.writeln();
        sb.write(f.text);
      }
    }
    return sb.toString();
  }

  @override
  Future<String> readText() async => content;

  @override
  Future<Uint8List> readData() async {
    for (final f in fields) {
      if (f.data != null) return f.data!;
    }
    return Uint8List.fromList(utf8.encode(content));
  }

  @override
  Future<Stream<List<int>>> openRead({int? start, int? end}) async {
    final bytes = await readData();
    final length = bytes.length;
    final s = (start ?? 0).clamp(0, length);
    final e = (end ?? length).clamp(s, length);
    if (s >= e) return Stream.value(Uint8List(0));
    return Stream.value(Uint8List.sublistView(bytes, s, e));
  }
}

/// Whether a StarDict type code holds a length-prefixed binary blob
/// (uppercase) rather than a NUL-terminated string (lowercase).
bool _isBinaryType(String type) =>
    type.isNotEmpty && type == type.toUpperCase() && type != type.toLowerCase();

/// Random-access reader for dictzip (`.dict.dz`) files.
///
/// A dictzip file is a gzip member whose extra field carries an "RA"
/// subfield describing independently compressed chunks, so any byte range
/// of the uncompressed data can be recovered by inflating only the chunks
/// that overlap it.
class DictZipReader {
  final RandomAccessFile _file;
  final int _headerSize;
  final int _chunkLength;
  final List<int> _chunkCompressedLengths;
  final int totalSize;
  final Map<int, Uint8List> _chunkCache = {};

  DictZipReader._(
    this._file,
    this._headerSize,
    this._chunkLength,
    this._chunkCompressedLengths,
    this.totalSize,
  );

  static Future<DictZipReader> open(RandomAccessFile file) async {
    await file.setPosition(0);
    final header = await file.read(4096);
    final bd = ByteData.sublistView(header);
    if (header.length < 18 || header[0] != 0x1f || header[1] != 0x8b) {
      throw const FormatException('Not a gzip file');
    }
    if (header[2] != 8) {
      throw const FormatException('Unsupported gzip compression method');
    }
    final flags = header[3];
    var pos = 10; // magic(2) method(1) flags(1) mtime(4) xfl(1) os(1)

    int? chunkLength;
    List<int>? chunkCompressedLengths;
    if (flags & 0x04 != 0) {
      // FEXTRA
      final xlen = bd.getUint16(pos, Endian.little);
      final extraStart = pos + 2;
      final extraEnd = extraStart + xlen;
      var p = extraStart;
      while (p + 4 <= extraEnd) {
        final si1 = header[p];
        final si2 = header[p + 1];
        final slen = bd.getUint16(p + 2, Endian.little);
        if (si1 == 0x52 && si2 == 0x41) {
          // 'RA' subfield: version(2) chlen(2) chcnt(2) then chcnt uint16
          // compressed chunk lengths.
          final dataStart = p + 4;
          chunkLength = bd.getUint16(dataStart + 2, Endian.little);
          final chunkCount = bd.getUint16(dataStart + 4, Endian.little);
          chunkCompressedLengths = [
            for (var i = 0; i < chunkCount; i++)
              bd.getUint16(dataStart + 6 + i * 2, Endian.little),
          ];
        }
        p += 4 + slen;
      }
      pos = extraEnd;
    }
    if (flags & 0x08 != 0) {
      // FNAME: NUL-terminated.
      while (header[pos] != 0) {
        pos++;
      }
      pos++;
    }
    if (flags & 0x10 != 0) {
      // FCOMMENT: NUL-terminated.
      while (header[pos] != 0) {
        pos++;
      }
      pos++;
    }
    if (flags & 0x02 != 0) {
      // FHCRC
      pos += 2;
    }
    if (chunkLength == null || chunkCompressedLengths == null) {
      throw const FormatException('gzip file has no dictzip RA extra field');
    }

    // The gzip trailer's ISIZE (last 4 bytes) is the total uncompressed size.
    final fileLength = await file.length();
    await file.setPosition(fileLength - 4);
    final trailer = await file.read(4);
    final totalSize = ByteData.sublistView(trailer).getUint32(0, Endian.little);

    return DictZipReader._(
      file,
      pos,
      chunkLength,
      chunkCompressedLengths,
      totalSize,
    );
  }

  int _compressedOffsetOfChunk(int chunk) {
    var offset = _headerSize;
    for (var i = 0; i < chunk; i++) {
      offset += _chunkCompressedLengths[i];
    }
    return offset;
  }

  Future<Uint8List> _readChunk(int chunk) async {
    final cached = _chunkCache[chunk];
    if (cached != null) return cached;
    await _file.setPosition(_compressedOffsetOfChunk(chunk));
    final compressed = await _file.read(_chunkCompressedLengths[chunk]);
    final inflated = ZLibDecoder(raw: true).convert(compressed);
    final result = Uint8List.fromList(inflated);
    if (_chunkCache.length > 32) _chunkCache.clear();
    _chunkCache[chunk] = result;
    return result;
  }

  /// Reads [length] uncompressed bytes starting at [offset].
  Future<Uint8List> read(int offset, int length) async {
    final out = BytesBuilder(copy: false);
    var remaining = length;
    var pos = offset;
    while (remaining > 0) {
      final chunk = pos ~/ _chunkLength;
      final within = pos % _chunkLength;
      final data = await _readChunk(chunk);
      final take =
          data.length - within < remaining ? data.length - within : remaining;
      out.add(Uint8List.sublistView(data, within, within + take));
      pos += take;
      remaining -= take;
    }
    return out.takeBytes();
  }
}

/// Reader for StarDict dictionaries (`.ifo` / `.idx` / `.dict` files, with
/// optional `.dict.dz` dictzip compression and a `.syn` synonym index).
///
/// The index files may use the compressed forms found in the wild: `.idx.gz`
/// and `.syn.gz` from the gzip spelling the format allows, and `.syn.dz`,
/// which PyGlossary writes when its `dictzip_syn` option is on. They are
/// decompressed transparently when the plain file is absent.
///
/// The reader is constructed with the dictionary's base path — the `.ifo`
/// path without its extension, the same identity the companion files share:
///
/// ```dart
/// final reader = StarDictReader('/path/to/MyDict');
/// await reader.init();
/// final entries = await reader.lookup('hello');
/// ```
class StarDictReader implements DictionaryReader {
  /// Base path of the dictionary: the `.ifo` path minus the extension.
  final String path;

  StarDictReader(this.path);

  final Map<String, String> _ifo = {};

  /// All key/value pairs parsed from the `.ifo` file.
  Map<String, String> get ifo => Map.unmodifiable(_ifo);

  @override
  String get title => bookName;

  String get bookName => _ifo['bookname'] ?? '';
  String get version => _ifo['version'] ?? '';
  String? get sameTypeSequence => _ifo['sametypesequence'];

  @override
  int get wordCount =>
      int.tryParse(_ifo['wordcount'] ?? '') ?? _idxEntryOffsets.length;

  @override
  Future<Uint8List?> getResource(String path) async => null;

  @override
  Future<Stream<List<int>>?> getResourceStream(
    String path, {
    int? start,
    int? end,
  }) async =>
      null;

  @override
  Future<Uint8List> exportCidx() =>
      throw UnsupportedError('exportCidx is not supported for StarDict');

  @override
  Future<void> importCidx(Uint8List bytes) =>
      throw UnsupportedError('importCidx is not supported for StarDict');

  // On-disk index state, built by init(). The `.idx` (and `.syn`) files
  // are themselves sorted indexes, so they are read whole into memory
  // and binary-searched in place: no headword strings, locations, or
  // lookup maps are materialized. Only entry start offsets are kept
  // (one int per entry), plus the prefix-search order below.
  Uint8List? _idxBytes;
  List<int> _idxEntryOffsets = [];
  // File-order `.idx` position -> sorted position. `.syn` targets are
  // file-order positions, so synonym resolution goes through this map.
  List<int> _idxFileToSorted = [];
  int _idxOffsetWidth = 4;
  Uint8List? _synBytes;
  List<int> _synEntryOffsets = [];
  // Prefix-search order: entry codes sorted by lowercase display word.
  // A code >= 0 is an `.idx` entry index; a code < 0 encodes a `.syn`
  // entry index as -(index + 1). The display word itself is decoded
  // from the index bytes on demand, so search() costs one decode per
  // binary-search probe plus one per returned match.
  List<int> _searchOrder = [];
  // NFC spelling -> entry index, only for headwords that are not NFC
  // themselves. Populated by the index parse; empty for most dictionaries.
  Map<String, int> _normalizedEntries = const {};
  Map<String, int> _normalizedSynonyms = const {};
  List<String>? _wordsCache;

  /// All headwords, in sorted index order. Decoded lazily on first
  /// access and cached; prefer [wordAt] for single lookups so a large
  /// dictionary is not decoded in full.
  @override
  List<String> get words {
    var cache = _wordsCache;
    if (cache == null) {
      cache = [for (var i = 0; i < _idxEntryOffsets.length; i++) _idxWordAt(i)];
      _wordsCache = cache;
    }
    return List.unmodifiable(cache);
  }

  /// The headword of the [index]-th `.idx` entry, decoded on demand.
  @override
  String wordAt(int index) => _idxWordAt(index);

  RandomAccessFile? _dictFile;
  DictZipReader? _dictZip;
  bool _initialized = false;

  File get _ifoFile => File('$path.ifo');

  /// The plain `.dict` file, or the `.dict.dz` when only the compressed
  /// form exists.
  File? get _dictSource {
    final plain = File('$path.dict');
    if (plain.existsSync()) return plain;
    final dz = File('$path.dict.dz');
    if (dz.existsSync()) return dz;
    return null;
  }

  bool get isDictZip => _dictSource?.path.endsWith('.dz') ?? false;

  bool _metadataInitialized = false;

  /// Reads only the `.ifo` metadata (book name, word count, ...), without
  /// touching the index or the entry data. Cheap; suitable for listing a
  /// dictionary before it is fully loaded.
  Future<void> initMetadata() async {
    if (_metadataInitialized) return;
    await _readIfo();
    _metadataInitialized = true;
  }

  /// Parses the `.ifo` metadata, the `.idx` word index and the optional
  /// `.syn` synonym index, and opens the `.dict` data for random access.
  ///
  /// The index parse runs in a background isolate: for dictionaries with
  /// hundreds of thousands of words it takes long enough to stall the
  /// caller's isolate (a UI isolate, in an app) if done inline.
  Future<void> init() async {
    if (_initialized) return;
    await initMetadata();
    final parsed = await Isolate.run(
      () => _parseStarDictIndex(path, _idxOffsetBits),
    );
    _idxBytes = parsed.idxBytes;
    _idxEntryOffsets = parsed.idxEntryOffsets;
    _idxFileToSorted = parsed.idxFileToSorted;
    _idxOffsetWidth = parsed.idxOffsetWidth;
    _synBytes = parsed.synBytes;
    _synEntryOffsets = parsed.synEntryOffsets;
    _searchOrder = parsed.searchOrder;
    _normalizedEntries = parsed.normalizedEntries;
    _normalizedSynonyms = parsed.normalizedSynonyms;
    final dictSource = _dictSource;
    if (dictSource == null) {
      throw StateError('StarDict dictionary data (.dict/.dict.dz) not found '
          'for $path');
    }
    _dictFile = await dictSource.open();
    if (dictSource.path.endsWith('.dz')) {
      _dictZip = await DictZipReader.open(_dictFile!);
    }
    _initialized = true;
  }

  Future<void> _readIfo() async {
    if (!await _ifoFile.exists()) {
      throw StateError('StarDict .ifo file not found: ${_ifoFile.path}');
    }
    final lines = await _ifoFile.readAsLines();
    for (final line in lines.skip(1)) {
      final eq = line.indexOf('=');
      if (eq > 0) {
        _ifo[line.substring(0, eq).trim()] = line.substring(eq + 1).trim();
      }
    }
    if (bookName.isEmpty) {
      throw const FormatException('StarDict .ifo has no bookname');
    }
  }

  int get _idxOffsetBits => _ifo['idxoffsetbits'] == '64' ? 64 : 32;

  String _idxWordAt(int entryIndex) {
    final start = _idxEntryOffsets[entryIndex];
    final end = _idxBytes!.indexOf(0, start);
    return utf8.decode(
      Uint8List.sublistView(_idxBytes!, start, end),
      allowMalformed: true,
    );
  }

  (int, int) _idxLocationAt(int entryIndex) {
    final start = _idxEntryOffsets[entryIndex];
    final end = _idxBytes!.indexOf(0, start);
    final data = ByteData.sublistView(_idxBytes!);
    var pos = end + 1;
    final offset = _idxOffsetWidth == 8
        ? data.getUint64(pos, Endian.big)
        : data.getUint32(pos, Endian.big);
    pos += _idxOffsetWidth;
    final size = data.getUint32(pos, Endian.big);
    return (offset, size);
  }

  /// First `.idx` entry whose word bytes are >= [queryBytes].
  int _idxLowerBound(List<int> queryBytes) {
    var lo = 0;
    var hi = _idxEntryOffsets.length;
    while (lo < hi) {
      final mid = (lo + hi) >> 1;
      final start = _idxEntryOffsets[mid];
      final end = _idxBytes!.indexOf(0, start);
      if (compareBytes(_idxBytes!, start, end - start, queryBytes) < 0) {
        lo = mid + 1;
      } else {
        hi = mid;
      }
    }
    return lo;
  }

  bool _idxKeyEquals(int entryIndex, List<int> queryBytes) {
    final start = _idxEntryOffsets[entryIndex];
    final end = _idxBytes!.indexOf(0, start);
    return end - start == queryBytes.length &&
        compareBytes(_idxBytes!, start, end - start, queryBytes) == 0;
  }

  int _synLowerBound(List<int> queryBytes) {
    var lo = 0;
    var hi = _synEntryOffsets.length;
    while (lo < hi) {
      final mid = (lo + hi) >> 1;
      final start = _synEntryOffsets[mid];
      final end = _synBytes!.indexOf(0, start);
      if (compareBytes(_synBytes!, start, end - start, queryBytes) < 0) {
        lo = mid + 1;
      } else {
        hi = mid;
      }
    }
    return lo;
  }

  bool _synKeyEquals(int synIndex, List<int> queryBytes) {
    final start = _synEntryOffsets[synIndex];
    final end = _synBytes!.indexOf(0, start);
    return end - start == queryBytes.length &&
        compareBytes(_synBytes!, start, end - start, queryBytes) == 0;
  }

  int _synTargetAt(int synIndex) {
    final start = _synEntryOffsets[synIndex];
    final end = _synBytes!.indexOf(0, start);
    return ByteData.sublistView(_synBytes!).getUint32(end + 1, Endian.big);
  }

  String _searchWordAt(int code) {
    if (code >= 0) return _idxWordAt(code);
    final synIndex = -code - 1;
    final start = _synEntryOffsets[synIndex];
    final end = _synBytes!.indexOf(0, start);
    return utf8.decode(
      Uint8List.sublistView(_synBytes!, start, end),
      allowMalformed: true,
    );
  }

  /// Whether [word] (or its lowercase form, or a synonym of it) has an
  /// entry in this dictionary.
  @override
  bool exist(String word) => resolveIndex(word) != null;

  /// Resolves [word] to an index position: exact match first, then the
  /// lowercase form, then the synonym index (which also tries lowercase).
  int? resolveIndex(String word) {
    // Exact spelling first: a stored NFC headword must win over a
    // decomposed twin that normalises to the same key, and the exact byte
    // search is what keeps the common path allocation-free.
    final query = utf8.encode(word);
    var index = _idxLowerBound(query);
    if (index < _idxEntryOffsets.length && _idxKeyEquals(index, query)) {
      return index;
    }
    if (_synBytes != null) {
      final syn = _synLowerBound(query);
      if (syn < _synEntryOffsets.length && _synKeyEquals(syn, query)) {
        final target = _synTargetAt(syn);
        if (target < _idxFileToSorted.length) {
          return _idxFileToSorted[target];
        }
      }
    }

    // Normalised spelling: a decomposed query must reach a composed
    // headword, and a composed query must reach a decomposed one. The byte
    // search below covers entries stored in NFC; the maps after it cover
    // entries stored decomposed, whose bytes can never equal the
    // normalised query.
    final lookup = normalizeKey(word);
    if (lookup != word) {
      final normalizedQuery = utf8.encode(lookup);
      index = _idxLowerBound(normalizedQuery);
      if (index < _idxEntryOffsets.length &&
          _idxKeyEquals(index, normalizedQuery)) {
        return index;
      }
      if (_synBytes != null) {
        final syn = _synLowerBound(normalizedQuery);
        if (syn < _synEntryOffsets.length &&
            _synKeyEquals(syn, normalizedQuery)) {
          final target = _synTargetAt(syn);
          if (target < _idxFileToSorted.length) {
            return _idxFileToSorted[target];
          }
        }
      }
    }
    final normalized = _normalizedEntries[lookup];
    if (normalized != null) return normalized;
    final normalizedSynonym = _normalizedSynonyms[lookup];
    if (normalizedSynonym != null) return normalizedSynonym;
    final lower = word.toLowerCase();
    if (lower != word) {
      final lowerQuery = utf8.encode(lower);
      index = _idxLowerBound(lowerQuery);
      if (index < _idxEntryOffsets.length && _idxKeyEquals(index, lowerQuery)) {
        return index;
      }
      if (_synBytes != null) {
        final syn = _synLowerBound(lowerQuery);
        if (syn < _synEntryOffsets.length && _synKeyEquals(syn, lowerQuery)) {
          final target = _synTargetAt(syn);
          if (target < _idxFileToSorted.length) {
            return _idxFileToSorted[target];
          }
        }
      }
    }
    return null;
  }

  /// All index positions carrying exactly [word] (a word may have several
  /// entries in the `.idx`).
  List<int> _indexRangeOf(String word) {
    final query = utf8.encode(word);
    final first = _idxLowerBound(query);
    if (first >= _idxEntryOffsets.length || !_idxKeyEquals(first, query)) {
      return const [];
    }
    final result = <int>[first];
    var i = first + 1;
    while (i < _idxEntryOffsets.length && _idxKeyEquals(i, query)) {
      result.add(i);
      i++;
    }
    return result;
  }

  /// Looks up [word] and returns its entries. Synonyms resolve to the
  /// entry of the word they point at. Returns an empty list when the word
  /// is not in the dictionary.
  @override
  Future<List<StarDictEntry>> lookup(String word) async {
    if (!_initialized) {
      throw StateError('StarDictReader.init() has not completed');
    }
    // A decomposed query has to be turned back into the dictionary's own
    // spelling before the byte search, otherwise the range is empty even
    // though `resolveIndex` can find the entry.
    var effective = word;
    if (normalizeKey(word) != word) {
      final target = resolveIndex(word);
      if (target != null) effective = _idxWordAt(target);
    }
    var indices = _indexRangeOf(effective);
    if (indices.isEmpty) {
      final lower = effective.toLowerCase();
      if (lower != effective) indices = _indexRangeOf(lower);
    }
    if (indices.isEmpty) {
      final target = resolveIndex(word);
      if (target != null) indices = [target];
    }
    final entries = <StarDictEntry>[];
    for (final i in indices) {
      final (offset, size) = _idxLocationAt(i);
      final raw = await _readDict(offset, size);
      entries.add(
        StarDictEntry(headword: _idxWordAt(i), fields: _decodeEntry(raw)),
      );
    }
    return entries;
  }

  /// Prefix search over the headwords and synonyms, case-insensitive,
  /// returning at most [limit] matches sorted alphabetically. Runs against
  /// the pre-sorted index built by [init] instead of scanning every word.
  @override
  List<String> search(String query, {int? limit = 30}) {
    if (query.isEmpty) return const [];
    final maxResults = limit ?? 30;
    // Normalise both sides: the search order is sorted by the lowercased NFC
    // form, so a decomposed query still lands on the right headwords.
    final lowerQuery = normalizeKey(query).toLowerCase();
    // Binary search over the lowercase-sorted search order, decoding
    // each probed word on the fly, then a short forward scan.
    var lo = 0;
    var hi = _searchOrder.length;
    while (lo < hi) {
      final mid = (lo + hi) >> 1;
      final probe =
          normalizeKey(_searchWordAt(_searchOrder[mid])).toLowerCase();
      if (probe.compareTo(lowerQuery) < 0) {
        lo = mid + 1;
      } else {
        hi = mid;
      }
    }
    final results = <String>[];
    for (var i = lo;
        i < _searchOrder.length && results.length < maxResults;
        i++) {
      final word = _searchWordAt(_searchOrder[i]);
      if (!normalizeKey(word).toLowerCase().startsWith(lowerQuery)) break;
      results.add(word);
    }
    return results;
  }

  @override
  Future<List<DictSearchResult>> searchFulltext(
    String query, {
    int limit = 20,
  }) async {
    if (query.isEmpty) return const [];
    final lowerQuery = normalizeKey(query).toLowerCase();
    final results = <DictSearchResult>[];
    final seen = <String>{};

    for (var i = 0; i < wordCount && results.length < limit; i++) {
      final word = wordAt(i);
      if (word.toLowerCase().contains(lowerQuery)) {
        if (seen.add(word)) {
          final entries = await lookup(word);
          if (entries.isNotEmpty) {
            final text = await entries.first.readText();
            results.add(DictSearchResult(
              article: entries.first,
              snippet: extractSnippet(text, query),
              score: word.toLowerCase() == lowerQuery ? 3.0 : 2.0,
            ));
          }
        }
      }
    }

    if (results.length < limit) {
      for (var i = 0; i < wordCount && results.length < limit; i++) {
        final word = wordAt(i);
        if (seen.contains(word)) continue;
        final entries = await lookup(word);
        if (entries.isEmpty) continue;
        final text = await entries.first.readText();
        if (text.toLowerCase().contains(lowerQuery)) {
          seen.add(word);
          results.add(DictSearchResult(
            article: entries.first,
            snippet: extractSnippet(text, query),
            score: 1.0,
          ));
        }
      }
    }

    results.sort((a, b) => b.score.compareTo(a.score));
    return results;
  }

  Future<Uint8List> _readDict(int offset, int size) async {
    if (_dictZip != null) {
      return _dictZip!.read(offset, size);
    }
    await _dictFile!.setPosition(offset);
    return _dictFile!.read(size);
  }

  /// Decodes one raw entry into typed fields, following the dictionary's
  /// `sametypesequence` when declared, or the per-field type markers
  /// embedded in the data otherwise.
  List<StarDictField> _decodeEntry(Uint8List raw) {
    final fields = <StarDictField>[];
    final sequence = sameTypeSequence;
    var pos = 0;

    StarDictField readField(String type) {
      if (_isBinaryType(type)) {
        final length = ByteData.sublistView(raw).getUint32(pos, Endian.big);
        pos += 4;
        final data = Uint8List.sublistView(raw, pos, pos + length);
        pos += length;
        return StarDictField(type, data: data);
      }
      final end = raw.indexOf(0, pos);
      final stop = end < 0 ? raw.length : end;
      final text = utf8.decode(
        Uint8List.sublistView(raw, pos, stop),
        allowMalformed: true,
      );
      pos = end < 0 ? raw.length : end + 1;
      return StarDictField(type, text: text);
    }

    if (sequence != null && sequence.isNotEmpty) {
      for (var i = 0; i < sequence.length && pos < raw.length; i++) {
        fields.add(readField(sequence[i]));
      }
    } else {
      while (pos < raw.length) {
        final type = String.fromCharCode(raw[pos]);
        pos++;
        fields.add(readField(type));
      }
    }
    return fields;
  }

  @override
  Future<void> close() async {
    await _dictFile?.close();
    _dictFile = null;
    _dictZip = null;
    _idxBytes = null;
    _idxEntryOffsets = [];
    _idxFileToSorted = [];
    _synBytes = null;
    _synEntryOffsets = [];
    _searchOrder = [];
    _wordsCache = null;
    _initialized = false;
  }
}

/// The parsed index of a StarDict dictionary: the raw `.idx` and `.syn`
/// bytes plus the entry start offsets and the prefix-search order,
/// produced by [_parseStarDictIndex]. No headword strings, locations,
/// or lookup maps are kept: lookups binary-search the bytes in place,
/// and display words are decoded on demand.
///
/// The search order encodes, per entry, a code: >= 0 is an `.idx` entry
/// index, < 0 is `-(syn entry index + 1)`. It is sorted by lowercase
/// display word, built exactly like the old key/word pair lists
/// (headwords first in first-occurrence order, then synonyms that do
/// not shadow a headword), so search results are unchanged.
class _ParsedStarDictIndex {
  final Uint8List idxBytes;
  final List<int> idxEntryOffsets;
  final List<int> idxFileToSorted;
  final int idxOffsetWidth;
  final Uint8List? synBytes;
  final List<int> synEntryOffsets;
  final List<int> searchOrder;

  /// NFC form -> sorted `.idx` entry index, for headwords whose spelling is
  /// not already NFC. Empty for the (common) dictionaries that need nothing.
  final Map<String, int> normalizedEntries;

  /// NFC form -> sorted `.idx` entry index a synonym points at.
  final Map<String, int> normalizedSynonyms;

  const _ParsedStarDictIndex({
    required this.idxBytes,
    required this.idxEntryOffsets,
    required this.idxFileToSorted,
    required this.idxOffsetWidth,
    required this.synBytes,
    required this.synEntryOffsets,
    required this.searchOrder,
    required this.normalizedEntries,
    required this.normalizedSynonyms,
  });
}

/// Reads a StarDict index file, transparently decompressing the `.gz` and
/// `.dz` forms the format allows when the plain file is absent. Returns null
/// when no form exists.
///
/// One decoder covers both. `.dz` is dictzip: a gzip member whose extra field
/// describes independently compressed chunks, and those chunks are one deflate
/// stream flushed at their boundaries, so inflating it front to back recovers
/// the whole file. Only random access needs the chunk table, which is why
/// `.dict.dz` reads through [DictZipReader] while an index — always wanted
/// whole — does not.
Uint8List? _readStarDictIndexFile(String path) {
  final plain = File(path);
  if (plain.existsSync()) return plain.readAsBytesSync();
  for (final suffix in const ['.gz', '.dz']) {
    final compressed = File('$path$suffix');
    if (compressed.existsSync()) {
      return Uint8List.fromList(
        GZipCodec().decode(compressed.readAsBytesSync()),
      );
    }
  }
  return null;
}

/// Parses the `.idx` (and `.syn`, when present) files of the dictionary at
/// [basePath]. Runs in a background isolate (see [StarDictReader.init]).
///
/// Only entry start offsets are collected (one linear scan per file);
/// words are decoded transiently for the search order and then dropped.
/// Malformed words are tolerated the same way as before: legacy
/// dictionaries occasionally carry a few words in a locale encoding, and
/// one bad word must not make the whole dictionary unloadable.
_ParsedStarDictIndex _parseStarDictIndex(String basePath, int idxOffsetBits) {
  final idxBytes = _readStarDictIndexFile('$basePath.idx');
  if (idxBytes == null) {
    throw StateError(
      'StarDict index (.idx/.idx.gz/.idx.dz) not found for $basePath',
    );
  }
  final offsetWidth = idxOffsetBits ~/ 8;
  final fileOrderOffsets = <int>[];
  var pos = 0;
  while (pos < idxBytes.length) {
    final end = idxBytes.indexOf(0, pos);
    if (end < 0) break;
    fileOrderOffsets.add(pos);
    pos = end + 1 + offsetWidth + 4;
  }

  String idxWordAtFileOrder(int fileIndex) {
    final start = fileOrderOffsets[fileIndex];
    final end = idxBytes.indexOf(0, start);
    return utf8.decode(
      Uint8List.sublistView(idxBytes, start, end),
      allowMalformed: true,
    );
  }

  // Entry offsets in word-byte order. Real `.idx` files are already
  // sorted, but sorting here (stable, so duplicates keep file order)
  // also keeps lookups working on files that are not, at the cost of
  // one int per entry.
  int wordEnd(int start) => idxBytes.indexOf(0, start);
  final sortedOrder = List<int>.generate(fileOrderOffsets.length, (i) => i)
    ..sort((a, b) {
      final startA = fileOrderOffsets[a];
      final startB = fileOrderOffsets[b];
      return compareBytes(
        idxBytes,
        startA,
        wordEnd(startA) - startA,
        idxBytes,
        startB,
        wordEnd(startB) - startB,
      );
    });
  final idxEntryOffsets = [
    for (final fileIndex in sortedOrder) fileOrderOffsets[fileIndex],
  ];
  final idxFileToSorted = List<int>.filled(fileOrderOffsets.length, 0);
  for (var sorted = 0; sorted < sortedOrder.length; sorted++) {
    idxFileToSorted[sortedOrder[sorted]] = sorted;
  }

  Uint8List? synBytes;
  final synEntryOffsets = <int>[];
  final synData = _readStarDictIndexFile('$basePath.syn');
  if (synData != null) {
    synBytes = synData;
    var synPos = 0;
    while (synPos < synData.length) {
      final end = synData.indexOf(0, synPos);
      if (end < 0) break;
      synEntryOffsets.add(synPos);
      synPos = end + 1 + 4;
    }
  }

  String synWordAt(int synIndex) {
    final start = synEntryOffsets[synIndex];
    final end = synBytes!.indexOf(0, start);
    return utf8.decode(
      Uint8List.sublistView(synBytes, start, end),
      allowMalformed: true,
    );
  }

  // Prefix-search order: headwords first (first occurrence wins, as
  // before), then synonyms that do not shadow a headword.
  final seenWords = <String>{};
  final pairs = <(String, int)>[];
  final normalizedEntries = <String, int>{};
  for (var i = 0; i < fileOrderOffsets.length; i++) {
    final word = idxWordAtFileOrder(i);
    if (seenWords.add(word)) {
      pairs.add((normalizeKey(word).toLowerCase(), idxFileToSorted[i]));
    }
    final lookup = normalizeKey(word);
    if (lookup != word) {
      normalizedEntries.putIfAbsent(lookup, () => idxFileToSorted[i]);
    }
  }
  final normalizedSynonyms = <String, int>{};
  if (synBytes != null) {
    final seenSynonyms = <String>{};
    for (var i = 0; i < synEntryOffsets.length; i++) {
      final word = synWordAt(i);
      if (!seenSynonyms.add(word)) continue;
      if (seenWords.contains(word)) continue;
      pairs.add((normalizeKey(word).toLowerCase(), -(i + 1)));
      final lookup = normalizeKey(word);
      if (lookup != word) {
        final start = synEntryOffsets[i];
        final end = synBytes.indexOf(0, start);
        if (end < 0 || end + 5 > synBytes.length) continue;
        final target =
            ByteData.sublistView(synBytes).getUint32(end + 1, Endian.big);
        if (target < idxFileToSorted.length) {
          normalizedSynonyms.putIfAbsent(
            lookup,
            () => idxFileToSorted[target],
          );
        }
      }
    }
  }
  // Dart's sort is stable, so equal lowercase keys keep pair order.
  pairs.sort((a, b) => a.$1.compareTo(b.$1));

  return _ParsedStarDictIndex(
    idxBytes: idxBytes,
    idxEntryOffsets: idxEntryOffsets,
    idxFileToSorted: idxFileToSorted,
    idxOffsetWidth: offsetWidth,
    synBytes: synBytes,
    synEntryOffsets: synEntryOffsets,
    searchOrder: [for (final pair in pairs) pair.$2],
    normalizedEntries: normalizedEntries,
    normalizedSynonyms: normalizedSynonyms,
  );
}
