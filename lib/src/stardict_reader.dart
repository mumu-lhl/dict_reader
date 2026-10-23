import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

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
class StarDictEntry {
  final String headword;
  final List<StarDictField> fields;

  const StarDictEntry({required this.headword, required this.fields});
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
/// The reader is constructed with the dictionary's base path — the `.ifo`
/// path without its extension, the same identity the companion files share:
///
/// ```dart
/// final reader = StarDictReader('/path/to/MyDict');
/// await reader.init();
/// final entries = await reader.lookup('hello');
/// ```
class StarDictReader {
  /// Base path of the dictionary: the `.ifo` path minus the extension.
  final String path;

  StarDictReader(this.path);

  final Map<String, String> _ifo = {};

  /// All key/value pairs parsed from the `.ifo` file.
  Map<String, String> get ifo => Map.unmodifiable(_ifo);

  String get bookName => _ifo['bookname'] ?? '';
  String get version => _ifo['version'] ?? '';
  String? get sameTypeSequence => _ifo['sametypesequence'];
  int get wordCount => int.tryParse(_ifo['wordcount'] ?? '') ?? _words.length;

  // Index structures, built by init().
  final List<String> _words = [];
  final List<(int, int)> _locations = []; // (offset, size) per word
  final Map<String, int> _wordToIndex = {};
  final Map<String, int> _synonymToIndex = {};
  // Prefix-search index: display words sorted by their lowercase form
  // (parallel lists), built once by init() so search() is a binary search
  // plus a short scan instead of a full pass over every word per query.
  final List<String> _searchKeys = [];
  final List<String> _searchWords = [];

  /// All headwords, in index order (suitable for prefix suggestions after
  /// sorting; see [search]).
  List<String> get words => List.unmodifiable(_words);

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
      () => _parseIndexFiles(path, _idxOffsetBits),
    );
    _words.addAll(parsed.words);
    _locations.addAll(parsed.locations);
    _wordToIndex.addAll(parsed.wordToIndex);
    _synonymToIndex.addAll(parsed.synonymToIndex);
    _searchKeys.addAll(parsed.searchKeys);
    _searchWords.addAll(parsed.searchWords);
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

  /// Whether [word] (or its lowercase form, or a synonym of it) has an
  /// entry in this dictionary.
  bool exist(String word) => resolveIndex(word) != null;

  /// Resolves [word] to an index position: exact match first, then the
  /// lowercase form, then the synonym index (which also tries lowercase).
  int? resolveIndex(String word) {
    final direct = _wordToIndex[word] ?? _synonymToIndex[word];
    if (direct != null) return direct;
    final lower = word.toLowerCase();
    if (lower != word) {
      return _wordToIndex[lower] ?? _synonymToIndex[lower];
    }
    return null;
  }

  /// All index positions carrying exactly [word] (a word may have several
  /// entries in the `.idx`).
  List<int> _indexRangeOf(String word) {
    final first = _wordToIndex[word];
    if (first == null) return const [];
    final result = <int>[first];
    var i = first + 1;
    while (i < _words.length && _words[i] == word) {
      result.add(i);
      i++;
    }
    return result;
  }

  /// Looks up [word] and returns its entries. Synonyms resolve to the
  /// entry of the word they point at. Returns an empty list when the word
  /// is not in the dictionary.
  Future<List<StarDictEntry>> lookup(String word) async {
    if (!_initialized) {
      throw StateError('StarDictReader.init() has not completed');
    }
    var indices = _indexRangeOf(word);
    if (indices.isEmpty) {
      final lower = word.toLowerCase();
      if (lower != word) indices = _indexRangeOf(lower);
    }
    if (indices.isEmpty) {
      final target = resolveIndex(word);
      if (target != null) indices = [target];
    }
    final entries = <StarDictEntry>[];
    for (final i in indices) {
      final (offset, size) = _locations[i];
      final raw = await _readDict(offset, size);
      entries.add(
        StarDictEntry(headword: _words[i], fields: _decodeEntry(raw)),
      );
    }
    return entries;
  }

  /// Prefix search over the headwords and synonyms, case-insensitive,
  /// returning at most [limit] matches sorted alphabetically. Runs against
  /// the pre-sorted index built by [init] instead of scanning every word.
  List<String> search(String query, {int limit = 30}) {
    if (query.isEmpty) return const [];
    final lowerQuery = query.toLowerCase();
    // Binary search for the first key that could carry the prefix, then
    // scan the matching run (bounded by limit).
    var lo = 0;
    var hi = _searchKeys.length;
    while (lo < hi) {
      final mid = (lo + hi) >> 1;
      if (_searchKeys[mid].compareTo(lowerQuery) < 0) {
        lo = mid + 1;
      } else {
        hi = mid;
      }
    }
    final results = <String>[];
    for (var i = lo; i < _searchKeys.length && results.length < limit; i++) {
      if (!_searchKeys[i].startsWith(lowerQuery)) break;
      results.add(_searchWords[i]);
    }
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

  Future<void> close() async {
    await _dictFile?.close();
    _dictFile = null;
    _dictZip = null;
    _initialized = false;
  }
}

/// The parsed index of a StarDict dictionary: everything [StarDictReader]
/// needs from the `.idx` and `.syn` files, produced by [_parseIndexFiles].
class _ParsedIndex {
  final List<String> words;
  final List<(int, int)> locations;
  final Map<String, int> wordToIndex;
  final Map<String, int> synonymToIndex;
  final List<String> searchKeys;
  final List<String> searchWords;

  const _ParsedIndex({
    required this.words,
    required this.locations,
    required this.wordToIndex,
    required this.synonymToIndex,
    required this.searchKeys,
    required this.searchWords,
  });
}

/// Parses the `.idx` (and `.syn`, when present) files of the dictionary at
/// [basePath]. Runs in a background isolate (see [StarDictReader.init]).
///
/// Words are decoded as UTF-8 with malformed sequences tolerated: legacy
/// dictionaries occasionally carry a few words in a locale encoding, and
/// one bad word must not make the whole dictionary unloadable — it just
/// becomes unfindable itself.
_ParsedIndex _parseIndexFiles(String basePath, int idxOffsetBits) {
  final words = <String>[];
  final locations = <(int, int)>[];
  final wordToIndex = <String, int>{};
  final synonymToIndex = <String, int>{};

  final idxBytes = File('$basePath.idx').readAsBytesSync();
  final idxData = ByteData.sublistView(idxBytes);
  final offsetWidth = idxOffsetBits ~/ 8;
  var pos = 0;
  var index = 0;
  while (pos < idxBytes.length) {
    final end = idxBytes.indexOf(0, pos);
    if (end < 0) break;
    final word = utf8.decode(
      Uint8List.sublistView(idxBytes, pos, end),
      allowMalformed: true,
    );
    pos = end + 1;
    final offset = offsetWidth == 8
        ? idxData.getUint64(pos, Endian.big)
        : idxData.getUint32(pos, Endian.big);
    pos += offsetWidth;
    final size = idxData.getUint32(pos, Endian.big);
    pos += 4;
    words.add(word);
    locations.add((offset, size));
    // First occurrence wins: .idx may repeat a word for multiple entries,
    // and lookup returns all of them via the contiguous range.
    wordToIndex.putIfAbsent(word, () => index);
    index++;
  }

  final synFile = File('$basePath.syn');
  if (synFile.existsSync()) {
    final synBytes = synFile.readAsBytesSync();
    final synData = ByteData.sublistView(synBytes);
    var synPos = 0;
    while (synPos < synBytes.length) {
      final end = synBytes.indexOf(0, synPos);
      if (end < 0) break;
      final word = utf8.decode(
        Uint8List.sublistView(synBytes, synPos, end),
        allowMalformed: true,
      );
      synPos = end + 1;
      final target = synData.getUint32(synPos, Endian.big);
      synPos += 4;
      if (target < words.length) {
        synonymToIndex.putIfAbsent(word, () => target);
      }
    }
  }

  // Prefix-search index: every suggestion surface (headwords first, then
  // synonyms that do not shadow a headword), sorted by lowercase form.
  final pairs = <(String, String)>[
    for (final word in wordToIndex.keys) (word.toLowerCase(), word),
    for (final word in synonymToIndex.keys)
      if (!wordToIndex.containsKey(word)) (word.toLowerCase(), word),
  ]..sort((a, b) => a.$1.compareTo(b.$1));

  return _ParsedIndex(
    words: words,
    locations: locations,
    wordToIndex: wordToIndex,
    synonymToIndex: synonymToIndex,
    searchKeys: [for (final pair in pairs) pair.$1],
    searchWords: [for (final pair in pairs) pair.$2],
  );
}
