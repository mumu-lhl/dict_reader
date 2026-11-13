import 'dart:async';
import 'dart:collection';
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

  /// Compressed-data offset of each chunk, relative to the start of the
  /// compressed data (i.e. excluding [_headerSize]): prefix sums over
  /// [_chunkCompressedLengths], computed once in [open], so
  /// [_compressedOffsetOfChunk] is an O(1) table lookup instead of an
  /// O(n) scan per chunk read.
  final List<int> _chunkCompressedOffsets;
  final int totalSize;

  /// Decompressed-chunk cache: a byte-capped LRU. [LinkedHashMap]
  /// iteration order is oldest first; a hit removes and re-inserts its
  /// chunk at the end, marking it most recently used. [_cacheBytes]
  /// tracks the total decompressed size so eviction can enforce
  /// [_maxChunkCacheBytes].
  final LinkedHashMap<int, Uint8List> _chunkCache = LinkedHashMap();
  int _cacheBytes = 0;
  static const int _maxChunkCacheBytes = 4 * 1024 * 1024;

  /// Chunk numbers currently in the decompression cache, oldest
  /// (least-recently-used) first. Exposed so tests can assert on LRU
  /// eviction behaviour.
  List<int> get cachedChunkOrder => List.unmodifiable(_chunkCache.keys);

  /// Total decompressed bytes currently held in the chunk cache.
  int get cachedChunkBytes => _cacheBytes;

  /// Maximum decompressed bytes the chunk cache may hold.
  int get maxChunkCacheBytes => _maxChunkCacheBytes;

  DictZipReader._(
    this._file,
    this._headerSize,
    this._chunkLength,
    this._chunkCompressedLengths,
    this._chunkCompressedOffsets,
    this.totalSize,
  );

  static Future<DictZipReader> open(RandomAccessFile file) async {
    await file.setPosition(0);
    var header = await file.read(4096);
    if (header.length < 18 || header[0] != 0x1f || header[1] != 0x8b) {
      throw const FormatException('Not a gzip file');
    }
    if (header[2] != 8) {
      throw const FormatException('Unsupported gzip compression method');
    }
    final flags = header[3];
    var pos = 10; // magic(2) method(1) flags(1) mtime(4) xfl(1) os(1)

    // The RA chunk table costs one uint16 per chunk, so a large
    // `.dict.dz` pushes the gzip header past the initial 4096-byte read
    // (>2037 chunks overflow it). Grow the buffered header on demand so
    // every field parsed below stays in range.
    Future<void> ensureBytes(int end) async {
      if (header.length >= end) return;
      final more = await file.read(end - header.length);
      header = Uint8List.fromList([...header, ...more]);
      if (header.length < end) {
        throw const FormatException('Truncated gzip header');
      }
    }

    int? chunkLength;
    List<int>? chunkCompressedLengths;
    if (flags & 0x04 != 0) {
      // FEXTRA
      final xlen = header[pos] | (header[pos + 1] << 8);
      final extraStart = pos + 2;
      final extraEnd = extraStart + xlen;
      await ensureBytes(extraEnd);
      final bd = ByteData.sublistView(header);
      var p = extraStart;
      while (p + 4 <= extraEnd) {
        final si1 = header[p];
        final si2 = header[p + 1];
        final slen = bd.getUint16(p + 2, Endian.little);
        if (si1 == 0x52 && si2 == 0x41 && slen >= 6) {
          // 'RA' subfield: version(2) chlen(2) chcnt(2) then chcnt uint16
          // compressed chunk lengths.
          final dataStart = p + 4;
          final chunkCount = bd.getUint16(dataStart + 4, Endian.little);
          if (dataStart + 6 + chunkCount * 2 > p + 4 + slen) {
            throw const FormatException('Truncated dictzip RA extra field');
          }
          chunkLength = bd.getUint16(dataStart + 2, Endian.little);
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
      // FNAME: NUL-terminated. It may itself run past the buffered
      // header, so keep reading until the terminator is found.
      while (true) {
        final end = header.indexOf(0, pos);
        if (end >= 0) {
          pos = end + 1;
          break;
        }
        final more = await file.read(256);
        if (more.isEmpty) {
          throw const FormatException('Truncated gzip header');
        }
        header = Uint8List.fromList([...header, ...more]);
      }
    }
    if (flags & 0x10 != 0) {
      // FCOMMENT: NUL-terminated.
      while (true) {
        final end = header.indexOf(0, pos);
        if (end >= 0) {
          pos = end + 1;
          break;
        }
        final more = await file.read(256);
        if (more.isEmpty) {
          throw const FormatException('Truncated gzip header');
        }
        header = Uint8List.fromList([...header, ...more]);
      }
    }
    if (flags & 0x02 != 0) {
      // FHCRC
      await ensureBytes(pos + 2);
      pos += 2;
    }
    if (chunkLength == null || chunkCompressedLengths == null) {
      throw const FormatException('gzip file has no dictzip RA extra field');
    }
    if (chunkLength == 0) {
      throw const FormatException('dictzip chunk length is zero');
    }

    // Prefix sums of the compressed chunk lengths: the compressed-data
    // offset of chunk i, with one extra entry holding the total.
    final chunkCompressedOffsets = <int>[0];
    for (final length in chunkCompressedLengths) {
      chunkCompressedOffsets.add(chunkCompressedOffsets.last + length);
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
      chunkCompressedOffsets,
      totalSize,
    );
  }

  int _compressedOffsetOfChunk(int chunk) =>
      _headerSize + _chunkCompressedOffsets[chunk];

  Future<Uint8List> _readChunk(int chunk) async {
    final cached = _chunkCache.remove(chunk);
    if (cached != null) {
      // Hit: re-insert at the end to mark it most recently used.
      _chunkCache[chunk] = cached;
      return cached;
    }
    await _file.setPosition(_compressedOffsetOfChunk(chunk));
    final compressed = await _file.read(_chunkCompressedLengths[chunk]);
    final inflated = ZLibDecoder(raw: true).convert(compressed);
    final result = Uint8List.fromList(inflated);
    _cacheChunk(chunk, result);
    return result;
  }

  /// Inserts a decompressed chunk into the cache, evicting
  /// least-recently-used chunks until the total cached bytes fit within
  /// [_maxChunkCacheBytes]. A single chunk larger than the whole budget
  /// is returned uncached, so the cap is never exceeded.
  void _cacheChunk(int chunk, Uint8List bytes) {
    if (bytes.length > _maxChunkCacheBytes) return;
    while (_cacheBytes + bytes.length > _maxChunkCacheBytes &&
        _chunkCache.isNotEmpty) {
      final oldest = _chunkCache.keys.first;
      final evicted = _chunkCache.remove(oldest)!;
      _cacheBytes -= evicted.length;
    }
    _chunkCache[chunk] = bytes;
    _cacheBytes += bytes.length;
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
  Future<Uint8List> exportCidx() async {
    if (!_initialized) {
      throw StateError('StarDictReader.init() has not completed');
    }
    final idxFile = _resolvedStarDictIndexFile('$path.idx');
    if (idxFile == null) {
      throw StateError(
        'StarDict index (.idx/.idx.gz/.idx.dz) not found for $path',
      );
    }
    final idxStat = await idxFile.stat();
    final idxPath = await idxFile.resolveSymbolicLinks();
    final synFile = _resolvedStarDictIndexFile('$path.syn');
    String? synPath;
    int? synFileSize;
    int? synFileModified;
    if (synFile != null) {
      final synStat = await synFile.stat();
      synPath = await synFile.resolveSymbolicLinks();
      synFileSize = synStat.size;
      synFileModified = synStat.modified.microsecondsSinceEpoch;
    }
    return _buildStarDictCidx(
      idxPath: idxPath,
      idxFileSize: idxStat.size,
      idxFileModified: idxStat.modified.microsecondsSinceEpoch,
      synPath: synPath,
      synFileSize: synFileSize,
      synFileModified: synFileModified,
      idxOffsetWidth: _idxOffsetWidth,
      idxEntryOffsets: _idxEntryOffsets,
      idxFileToSorted: _idxFileToSorted,
      synEntryOffsets: _synEntryOffsets,
      searchOrder: _searchOrder,
      normalizedEntries: _normalizedEntries,
      normalizedSynonyms: _normalizedSynonyms,
    );
  }

  @override
  Future<void> importCidx(Uint8List bytes) async {
    // Parse and structurally validate first: a bad cache must not disturb
    // a reader that is already working.
    final cidx = _parseStarDictCidx(bytes);
    if (_initialized) await close();
    await initMetadata();

    // The `.idx`/`.syn` bytes themselves are not cached — they already
    // live on disk — so re-read them and check the fingerprint: a cache
    // built from different bytes must be rejected so the caller can fall
    // back to a full parse.
    final idxBytes = _readStarDictIndexFile('$path.idx');
    if (idxBytes == null) {
      throw StateError(
        'StarDict index (.idx/.idx.gz/.idx.dz) not found for $path',
      );
    }
    final idxFile = _resolvedStarDictIndexFile('$path.idx');
    if (idxFile == null) {
      throw StateError('StarDict index (.idx/.idx.gz/.idx.dz) not found '
          'for $path');
    }
    final idxPath = await idxFile.resolveSymbolicLinks();
    final idxStat = await idxFile.stat();
    if (idxPath != cidx.idxPath ||
        idxStat.size != cidx.idxFileSize ||
        idxStat.modified.microsecondsSinceEpoch != cidx.idxFileModified) {
      throw const FormatException(
        'StarDict index file has changed since the .cidx was exported',
      );
    }
    Uint8List? synBytes;
    if (cidx.synPath != null) {
      final synFile = _resolvedStarDictIndexFile('$path.syn');
      if (synFile == null) {
        throw const FormatException(
          'StarDict synonym index is missing since the .cidx was exported',
        );
      }
      final synPath = await synFile.resolveSymbolicLinks();
      final synStat = await synFile.stat();
      if (synPath != cidx.synPath ||
          synStat.size != cidx.synFileSize ||
          synStat.modified.microsecondsSinceEpoch != cidx.synFileModified) {
        throw const FormatException(
          'StarDict synonym index has changed since the .cidx was exported',
        );
      }
      synBytes = _readStarDictIndexFile('$path.syn');
    } else if (_resolvedStarDictIndexFile('$path.syn') != null) {
      throw const FormatException(
        'StarDict synonym index appeared since the .cidx was exported',
      );
    }
    if (synBytes == null && cidx.synEntryOffsets.isNotEmpty) {
      throw const FormatException(
        'StarDict .cidx carries synonym entries but no synonym index',
      );
    }
    // Cross-check the cached offsets against the re-read index bytes:
    // walking the `.idx` yields the file-order entry starts, and the
    // cached sorted-order offsets must be exactly that set, with
    // `idxFileToSorted` mapping each file-order position to its sorted
    // position. This rejects a cache whose offsets point at the wrong
    // entries without trusting the fingerprint alone.
    final fileOrderOffsets = <int>[];
    var idxPos = 0;
    while (idxPos < idxBytes.length) {
      final end = idxBytes.indexOf(0, idxPos);
      if (end < 0) break;
      fileOrderOffsets.add(idxPos);
      idxPos = end + 1 + cidx.idxOffsetWidth + 4;
    }
    if (fileOrderOffsets.length != cidx.idxEntryOffsets.length) {
      throw const FormatException(
        'StarDict .cidx entry count does not match the index file',
      );
    }
    final sortedCached = [...cidx.idxEntryOffsets]..sort();
    final sortedFileOrder = [...fileOrderOffsets]..sort();
    for (var i = 0; i < sortedCached.length; i++) {
      if (sortedCached[i] != sortedFileOrder[i]) {
        throw const FormatException(
          'StarDict .cidx entry offsets do not match the index file',
        );
      }
    }
    for (var f = 0; f < fileOrderOffsets.length; f++) {
      if (cidx.idxEntryOffsets[cidx.idxFileToSorted[f]] !=
          fileOrderOffsets[f]) {
        throw const FormatException(
          'StarDict .cidx file-order map does not match the index file',
        );
      }
    }
    if (synBytes != null) {
      final synFileOrderOffsets = <int>[];
      var synPos = 0;
      while (synPos < synBytes.length) {
        final end = synBytes.indexOf(0, synPos);
        if (end < 0) break;
        synFileOrderOffsets.add(synPos);
        synPos = end + 1 + 4;
      }
      if (synFileOrderOffsets.length != cidx.synEntryOffsets.length) {
        throw const FormatException(
          'StarDict .cidx synonym count does not match the synonym index',
        );
      }
      for (var i = 0; i < synFileOrderOffsets.length; i++) {
        if (synFileOrderOffsets[i] != cidx.synEntryOffsets[i]) {
          throw const FormatException(
            'StarDict .cidx synonym offsets do not match the synonym index',
          );
        }
      }
    }

    _idxBytes = idxBytes;
    _idxEntryOffsets = cidx.idxEntryOffsets;
    _idxFileToSorted = cidx.idxFileToSorted;
    _idxOffsetWidth = cidx.idxOffsetWidth;
    _synBytes = synBytes;
    _synEntryOffsets = cidx.synEntryOffsets;
    _searchOrder = cidx.searchOrder;
    _normalizedEntries = cidx.normalizedEntries;
    _normalizedSynonyms = cidx.normalizedSynonyms;
    _wordsCache = null;
    await _openDictSource();
    _initialized = true;
  }

  /// Opens the `.dict` data source (plain or `.dict.dz`) for random
  /// access, shared by [init] and [importCidx].
  Future<void> _openDictSource() async {
    final dictSource = _dictSource;
    if (dictSource == null) {
      throw StateError('StarDict dictionary data (.dict/.dict.dz) not found '
          'for $path');
    }
    _dictFile = await dictSource.open();
    if (dictSource.path.endsWith('.dz')) {
      _dictZip = await DictZipReader.open(_dictFile!);
    }
  }

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

  /// Serializes every operation that touches the shared [_dictFile] handle.
  /// Dart's [RandomAccessFile] throws `FileSystemException: An async operation
  /// is currently pending` when a second `setPosition`/`read` starts while
  /// another is in flight, and the handle's position is shared state — so
  /// concurrent lookups must never interleave on it. The same lock also
  /// serializes [DictZipReader]'s chunk-cache mutations, which share the
  /// handle. The lock is a future chain: each holder awaits its predecessor
  /// and completes its own link on release, so an action that throws still
  /// unblocks the next waiter.
  Future<void> _fileLock = Future.value();

  Future<T> _withFileLock<T>(Future<T> Function() action) async {
    final previous = _fileLock;
    final gate = Completer<void>();
    _fileLock = gate.future;
    await previous;
    try {
      return await action();
    } finally {
      gate.complete();
    }
  }

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
    // Copy the path and offset width to locals: the isolate closure must
    // not capture `this` (the reader holds unsendable state such as the
    // file-access lock future, and Isolate.run rejects the whole object
    // graph when it does).
    final basePath = path;
    final offsetBits = _idxOffsetBits;
    final parsed = await Isolate.run(
      () => _parseStarDictIndex(basePath, offsetBits),
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
    await _openDictSource();
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

  /// Reads [size] bytes at [offset] from the `.dict`/`.dict.dz` data,
  /// serialized through [_withFileLock]: [_dictFile] is a single shared
  /// handle whose position must not be moved by concurrent lookups, and
  /// [DictZipReader.read] is only ever reached from here.
  Future<Uint8List> _readDict(int offset, int size) =>
      _withFileLock(() => _readDictLocked(offset, size));

  Future<Uint8List> _readDictLocked(int offset, int size) async {
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

/// Compact on-disk binary index (`.cidx`) for StarDict dictionaries.
///
/// Unlike the MDX `.cidx` ([buildCidx]), this stores no key bytes: the
/// `.idx` and `.syn` files are themselves the sorted indexes and stay on
/// disk, so only the derived state a full parse produces is cached — the
/// entry offsets, the file-order -> sorted-order map, the prefix-search
/// order, and the NFC maps for non-NFC spellings. [importCidx] re-reads
/// the `.idx`/`.syn` bytes from disk and validates them against the
/// fingerprint in the header before installing the cached state.
///
/// Layout (all integers big-endian):
///
/// ```text
/// header:
///   magic            4 bytes  "SDIX"
///   version          u32      1
///   unicodeVersion   u32      Unicode tables used to normalise, major*100+minor
///   idxOffsetWidth   u32      4 or 8 (bytes of the .idx data offset)
///   idxPathLength    u32
///   idxPath          bytes    resolved .idx path (UTF-8)
///   idxFileSize      u64
///   idxFileModified  u64      microseconds since epoch
///   synPresent       u32      0 = no .syn at export, 1 = present
///   [synPathLength   u32
///    synPath         bytes    resolved .syn path (UTF-8)
///    synFileSize     u64
///    synFileModified u64]     only when synPresent == 1
///   idxEntryCount    u64
///   synEntryCount    u64
///   searchOrderCount u64
///   normEntryCount   u64
///   normSynCount     u64
/// body:
///   idxEntryOffsets  idxEntryCount * u64, distinct (sorted order, so
///                      not increasing; import cross-checks them against
///                      the re-read `.idx`)
///   idxFileToSorted  idxEntryCount * u64, a permutation of 0..n-1
///   synEntryOffsets  synEntryCount * u64, strictly increasing
///   searchOrder      searchOrderCount * i64 (negative codes are synonyms)
///   normalizedEntries  normEntryCount * { keyLength u32, key bytes, value u64 }
///   normalizedSynonyms normSynCount  * { keyLength u32, key bytes, value u64 }
/// ```
const _sdixVersion = 1;

/// A parsed StarDict `.cidx` file: the fingerprint header plus the
/// derived index state, as produced by [_parseStarDictCidx].
class _StarDictCidxData {
  final String idxPath;
  final int idxFileSize;
  final int idxFileModified;
  final String? synPath;
  final int? synFileSize;
  final int? synFileModified;
  final int idxOffsetWidth;
  final List<int> idxEntryOffsets;
  final List<int> idxFileToSorted;
  final List<int> synEntryOffsets;
  final List<int> searchOrder;
  final Map<String, int> normalizedEntries;
  final Map<String, int> normalizedSynonyms;

  const _StarDictCidxData({
    required this.idxPath,
    required this.idxFileSize,
    required this.idxFileModified,
    required this.synPath,
    required this.synFileSize,
    required this.synFileModified,
    required this.idxOffsetWidth,
    required this.idxEntryOffsets,
    required this.idxFileToSorted,
    required this.synEntryOffsets,
    required this.searchOrder,
    required this.normalizedEntries,
    required this.normalizedSynonyms,
  });
}

/// The on-disk file [_readStarDictIndexFile] actually reads for [path]:
/// the plain file when it exists, else `.gz`, else `.dz`, else null.
/// The fingerprint in a StarDict `.cidx` names this file, not the base
/// path, so the form that was parsed is the form that is checked.
File? _resolvedStarDictIndexFile(String path) {
  final plain = File(path);
  if (plain.existsSync()) return plain;
  for (final suffix in const ['.gz', '.dz']) {
    final compressed = File('$path$suffix');
    if (compressed.existsSync()) return compressed;
  }
  return null;
}

Uint8List _buildStarDictCidx({
  required String idxPath,
  required int idxFileSize,
  required int idxFileModified,
  required String? synPath,
  required int? synFileSize,
  required int? synFileModified,
  required int idxOffsetWidth,
  required List<int> idxEntryOffsets,
  required List<int> idxFileToSorted,
  required List<int> synEntryOffsets,
  required List<int> searchOrder,
  required Map<String, int> normalizedEntries,
  required Map<String, int> normalizedSynonyms,
}) {
  final idxPathBytes = utf8.encode(idxPath);
  final synPathBytes = synPath == null ? null : utf8.encode(synPath);
  // Deterministic output: the NFC maps are written sorted by key.
  final normEntryKeys = normalizedEntries.keys.toList()..sort();
  final normEntryKeyBytes = [
    for (final key in normEntryKeys) utf8.encode(key),
  ];
  final normSynKeys = normalizedSynonyms.keys.toList()..sort();
  final normSynKeyBytes = [
    for (final key in normSynKeys) utf8.encode(key),
  ];
  var headerSize = 4 + 4 + 4 + 4 + 4 + idxPathBytes.length + 8 + 8 + 4;
  if (synPathBytes != null) {
    headerSize += 4 + synPathBytes.length + 8 + 8;
  }
  headerSize += 8 + 8 + 8 + 8 + 8;
  var bodySize = (idxEntryOffsets.length + idxFileToSorted.length) * 8 +
      synEntryOffsets.length * 8 +
      searchOrder.length * 8;
  for (final keyBytes in normEntryKeyBytes) {
    bodySize += 4 + keyBytes.length + 8;
  }
  for (final keyBytes in normSynKeyBytes) {
    bodySize += 4 + keyBytes.length + 8;
  }

  final out = Uint8List(headerSize + bodySize);
  final data = ByteData.sublistView(out);
  var pos = 0;
  out.setRange(pos, pos + 4, [0x53, 0x44, 0x49, 0x58]); // "SDIX"
  pos += 4;
  data.setUint32(pos, _sdixVersion, Endian.big);
  pos += 4;
  data.setUint32(pos, normalizationUnicodeVersion, Endian.big);
  pos += 4;
  data.setUint32(pos, idxOffsetWidth, Endian.big);
  pos += 4;
  data.setUint32(pos, idxPathBytes.length, Endian.big);
  pos += 4;
  out.setRange(pos, pos + idxPathBytes.length, idxPathBytes);
  pos += idxPathBytes.length;
  data.setUint64(pos, idxFileSize, Endian.big);
  pos += 8;
  data.setUint64(pos, idxFileModified, Endian.big);
  pos += 8;
  data.setUint32(pos, synPathBytes == null ? 0 : 1, Endian.big);
  pos += 4;
  if (synPathBytes != null) {
    data.setUint32(pos, synPathBytes.length, Endian.big);
    pos += 4;
    out.setRange(pos, pos + synPathBytes.length, synPathBytes);
    pos += synPathBytes.length;
    data.setUint64(pos, synFileSize!, Endian.big);
    pos += 8;
    data.setUint64(pos, synFileModified!, Endian.big);
    pos += 8;
  }
  data.setUint64(pos, idxEntryOffsets.length, Endian.big);
  pos += 8;
  data.setUint64(pos, synEntryOffsets.length, Endian.big);
  pos += 8;
  data.setUint64(pos, searchOrder.length, Endian.big);
  pos += 8;
  data.setUint64(pos, normEntryKeys.length, Endian.big);
  pos += 8;
  data.setUint64(pos, normSynKeys.length, Endian.big);
  pos += 8;
  for (final offset in idxEntryOffsets) {
    data.setUint64(pos, offset, Endian.big);
    pos += 8;
  }
  for (final sorted in idxFileToSorted) {
    data.setUint64(pos, sorted, Endian.big);
    pos += 8;
  }
  for (final offset in synEntryOffsets) {
    data.setUint64(pos, offset, Endian.big);
    pos += 8;
  }
  for (final code in searchOrder) {
    data.setInt64(pos, code, Endian.big);
    pos += 8;
  }
  for (var i = 0; i < normEntryKeys.length; i++) {
    final keyBytes = normEntryKeyBytes[i];
    data.setUint32(pos, keyBytes.length, Endian.big);
    pos += 4;
    out.setRange(pos, pos + keyBytes.length, keyBytes);
    pos += keyBytes.length;
    data.setUint64(pos, normalizedEntries[normEntryKeys[i]]!, Endian.big);
    pos += 8;
  }
  for (var i = 0; i < normSynKeys.length; i++) {
    final keyBytes = normSynKeyBytes[i];
    data.setUint32(pos, keyBytes.length, Endian.big);
    pos += 4;
    out.setRange(pos, pos + keyBytes.length, keyBytes);
    pos += keyBytes.length;
    data.setUint64(pos, normalizedSynonyms[normSynKeys[i]]!, Endian.big);
    pos += 8;
  }
  return out;
}

/// Parses and fully validates a StarDict `.cidx` file: magic, version,
/// Unicode tables, offset width, and a linear walk over every section
/// (synonym offsets strictly increasing, entry offsets distinct, the
/// file-order map a permutation, search codes in range and duplicate-free,
/// NFC map values in range, the body exactly consumed). Throws
/// [FormatException] on any inconsistency, including a cache built with
/// different normalisation tables — callers fall back to a full parse in
/// that case.
_StarDictCidxData _parseStarDictCidx(Uint8List bytes) {
  final data = ByteData.sublistView(bytes);
  var pos = 0;

  int need(int count) {
    if (pos + count > bytes.length) {
      throw const FormatException('Truncated StarDict .cidx file');
    }
    final value = pos;
    pos += count;
    return value;
  }

  int u32() => data.getUint32(need(4), Endian.big);
  int u64() => data.getUint64(need(8), Endian.big);
  int i64() => data.getInt64(need(8), Endian.big);

  if (bytes.length < 4 ||
      bytes[0] != 0x53 ||
      bytes[1] != 0x44 ||
      bytes[2] != 0x49 ||
      bytes[3] != 0x58) {
    throw const FormatException('Not a StarDict .cidx file');
  }
  pos = 4;
  if (u32() != _sdixVersion) {
    throw const FormatException('Unsupported StarDict .cidx version');
  }
  if (u32() != normalizationUnicodeVersion) {
    throw const FormatException('Stale StarDict .cidx Unicode tables');
  }
  final idxOffsetWidth = u32();
  if (idxOffsetWidth != 4 && idxOffsetWidth != 8) {
    throw const FormatException('Invalid StarDict .cidx offset width');
  }
  final idxPathLength = u32();
  final idxPathStart = need(idxPathLength);
  final idxPath = utf8.decode(
    Uint8List.sublistView(bytes, idxPathStart, idxPathStart + idxPathLength),
  );
  final idxFileSize = u64();
  final idxFileModified = u64();
  final synPresent = u32();
  if (synPresent != 0 && synPresent != 1) {
    throw const FormatException('Invalid StarDict .cidx synonym flag');
  }
  String? synPath;
  int? synFileSize;
  int? synFileModified;
  if (synPresent == 1) {
    final synPathLength = u32();
    final synPathStart = need(synPathLength);
    synPath = utf8.decode(
      Uint8List.sublistView(
        bytes,
        synPathStart,
        synPathStart + synPathLength,
      ),
    );
    synFileSize = u64();
    synFileModified = u64();
  }
  final idxEntryCount = u64();
  final synEntryCount = u64();
  final searchOrderCount = u64();
  final normEntryCount = u64();
  final normSynCount = u64();
  if (synPresent == 0 && synEntryCount != 0) {
    throw const FormatException(
      'StarDict .cidx has synonym entries but no synonym index',
    );
  }

  final idxEntryOffsets = <int>[];
  for (var i = 0; i < idxEntryCount; i++) {
    idxEntryOffsets.add(u64());
  }
  final idxFileToSorted = <int>[];
  for (var i = 0; i < idxEntryCount; i++) {
    idxFileToSorted.add(u64());
  }
  final synEntryOffsets = <int>[];
  for (var i = 0; i < synEntryCount; i++) {
    synEntryOffsets.add(u64());
  }
  final searchOrder = <int>[];
  for (var i = 0; i < searchOrderCount; i++) {
    searchOrder.add(i64());
  }
  Map<String, int> readNormMap(int count) {
    final map = <String, int>{};
    for (var i = 0; i < count; i++) {
      final keyLength = u32();
      final keyStart = need(keyLength);
      final key = utf8.decode(
        Uint8List.sublistView(bytes, keyStart, keyStart + keyLength),
      );
      final value = u64();
      if (map.containsKey(key)) {
        throw const FormatException(
          'StarDict .cidx has a duplicate normalised key',
        );
      }
      map[key] = value;
    }
    return map;
  }

  final normalizedEntries = readNormMap(normEntryCount);
  final normalizedSynonyms = readNormMap(normSynCount);
  if (pos != bytes.length) {
    throw const FormatException('StarDict .cidx has trailing bytes');
  }

  // Structural validation of the derived state, so a corrupt cache is
  // rejected here rather than producing wrong lookups later. The entry
  // offsets are in sorted order, so only distinctness can be checked
  // without the index bytes; importCidx cross-checks them against the
  // re-read `.idx` (same for the file-order map).
  if (idxEntryOffsets.toSet().length != idxEntryOffsets.length) {
    throw const FormatException(
      'StarDict .cidx entry offsets are not distinct',
    );
  }
  for (var i = 1; i < synEntryOffsets.length; i++) {
    if (synEntryOffsets[i] <= synEntryOffsets[i - 1]) {
      throw const FormatException(
        'StarDict .cidx synonym offsets are not increasing',
      );
    }
  }
  final seenSorted = Uint8List(idxEntryCount);
  for (final sorted in idxFileToSorted) {
    if (sorted < 0 || sorted >= idxEntryCount || seenSorted[sorted] == 1) {
      throw const FormatException(
        'StarDict .cidx file-order map is not a permutation',
      );
    }
    seenSorted[sorted] = 1;
  }
  final seenCodes = <int>{};
  for (final code in searchOrder) {
    if (code >= 0) {
      if (code >= idxEntryCount) {
        throw const FormatException(
          'StarDict .cidx search code is out of range',
        );
      }
    } else if (-code - 1 < 0 || -code - 1 >= synEntryCount) {
      throw const FormatException(
        'StarDict .cidx search code is out of range',
      );
    }
    if (!seenCodes.add(code)) {
      throw const FormatException(
        'StarDict .cidx search order has a duplicate code',
      );
    }
  }
  for (final value in normalizedEntries.values) {
    if (value < 0 || value >= idxEntryCount) {
      throw const FormatException(
        'StarDict .cidx normalised entry is out of range',
      );
    }
  }
  for (final value in normalizedSynonyms.values) {
    if (value < 0 || value >= idxEntryCount) {
      throw const FormatException(
        'StarDict .cidx normalised synonym is out of range',
      );
    }
  }

  return _StarDictCidxData(
    idxPath: idxPath,
    idxFileSize: idxFileSize,
    idxFileModified: idxFileModified,
    synPath: synPath,
    synFileSize: synFileSize,
    synFileModified: synFileModified,
    idxOffsetWidth: idxOffsetWidth,
    idxEntryOffsets: idxEntryOffsets,
    idxFileToSorted: idxFileToSorted,
    synEntryOffsets: synEntryOffsets,
    searchOrder: searchOrder,
    normalizedEntries: normalizedEntries,
    normalizedSynonyms: normalizedSynonyms,
  );
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

/// Whether [word] is pure lowercase ASCII: no code unit above 0x7F and
/// no uppercase letter (A-Z). [normalizeKey] is the identity on ASCII
/// (see normalize.dart) and [String.toLowerCase] is the identity without
/// an uppercase letter, so such a word is already its own lowercase NFC
/// search key and can never contribute a normalised entry.
bool _isLowerAscii(String word) {
  for (var i = 0; i < word.length; i++) {
    final unit = word.codeUnitAt(i);
    if (unit > 0x7F || (unit >= 0x41 && unit <= 0x5A)) return false;
  }
  return true;
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
  final sortedOrder = List<int>.generate(fileOrderOffsets.length, (i) => i);
  // Most `.idx` files are already in byte order: one linear scan proves
  // it, and the identity permutation is exactly what the stable sort
  // below would produce for such a file, so skip the O(n log n) sort.
  var alreadySorted = true;
  for (var i = 1; i < fileOrderOffsets.length; i++) {
    final prevStart = fileOrderOffsets[i - 1];
    final start = fileOrderOffsets[i];
    if (compareBytes(
          idxBytes,
          prevStart,
          wordEnd(prevStart) - prevStart,
          idxBytes,
          start,
          wordEnd(start) - start,
        ) >
        0) {
      alreadySorted = false;
      break;
    }
  }
  if (!alreadySorted) {
    sortedOrder.sort((a, b) {
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
  }
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
    // A lowercase-ASCII word is already its own lowercase NFC key
    // ([normalizeKey] is the identity on ASCII, and toLowerCase is the
    // identity without an uppercase letter), so it needs neither call.
    // Anything else is normalised once and the result reused for both
    // the search key and the normalised-entry map.
    final String key;
    final String lookup;
    if (_isLowerAscii(word)) {
      key = word;
      lookup = word;
    } else {
      lookup = normalizeKey(word);
      key = lookup.toLowerCase();
    }
    if (seenWords.add(word)) {
      pairs.add((key, idxFileToSorted[i]));
    }
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
      final String key;
      final String lookup;
      if (_isLowerAscii(word)) {
        key = word;
        lookup = word;
      } else {
        lookup = normalizeKey(word);
        key = lookup.toLowerCase();
      }
      pairs.add((key, -(i + 1)));
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
