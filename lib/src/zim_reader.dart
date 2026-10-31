import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:archive/archive.dart';

import 'dictionary_reader.dart';
import 'exceptions.dart';
import 'normalize.dart';
import 'zim_cidx.dart';

export 'zim_cidx.dart';

/// A single entry inside a ZIM archive (article, image, redirect, metadata, etc.).
class ZimEntry implements DictArticle {
  /// Index in the path pointer list.
  final int index;

  /// Single-character namespace ('A' for articles, 'I' for images, 'M' for metadata,
  /// 'C' for content in new namespace, '-' for layout, etc.).
  final String namespace;

  /// Resource path within the namespace (e.g. "apple" or "images/pic.png").
  final String path;

  /// Display title of the entry. If not explicitly specified in the archive,
  /// it defaults to [path].
  final String title;

  @override
  String get headword => title;

  @override
  String get format => 'zim';

  @override
  dynamic get raw => this;

  /// MIME type string (e.g. "text/html", "image/png").
  @override
  final String mimeType;

  /// Whether this entry is a redirect pointing to another entry.
  final bool isRedirect;

  /// If this is a redirect, the direct entry index of the target.
  final int? redirectIndex;

  /// Cluster number in which the entry data is stored.
  final int clusterNumber;

  /// Blob number inside the cluster.
  final int blobNumber;

  /// The parent [ZimReader].
  final ZimReader reader;

  /// If this entry was resolved via a redirect lookup, the original queried word/title.
  final String? resolvedFrom;

  const ZimEntry({
    required this.index,
    required this.namespace,
    required this.path,
    required this.title,
    required this.mimeType,
    required this.isRedirect,
    this.redirectIndex,
    required this.clusterNumber,
    required this.blobNumber,
    required this.reader,
    this.resolvedFrom,
  });

  /// Full path including the namespace prefix, e.g. "A/apple" or "I/photo.png".
  String get fullPath => '$namespace/$path';

  /// Whether this entry is an HTML/XHTML article.
  bool get isHtml =>
      mimeType == 'text/html' || mimeType == 'application/xhtml+xml';

  /// Whether this entry is an image.
  bool get isImage => mimeType.startsWith('image/');

  /// Whether this entry is a CSS stylesheet.
  bool get isCss => mimeType == 'text/css';

  /// Whether this entry is JavaScript.
  bool get isJs =>
      mimeType == 'application/javascript' || mimeType == 'text/javascript';

  /// Reads the raw data bytes of this entry from its cluster blob.
  @override
  Future<Uint8List> readData() => reader.readBlob(clusterNumber, blobNumber);

  /// Reads the entry data decoded as text.
  @override
  Future<String> readText([Encoding encoding = utf8]) async {
    final bytes = await readData();
    return encoding.decode(bytes);
  }

  /// Opens a byte stream for reading this entry's blob, optionally constrained
  /// to the byte range [start] (inclusive) up to [end] (exclusive).
  @override
  Future<Stream<List<int>>> openRead({int? start, int? end}) =>
      reader.readBlobStream(clusterNumber, blobNumber, start: start, end: end);

  @override
  String toString() =>
      'ZimEntry($fullPath, title: "$title", mime: $mimeType, redirect: $isRedirect)';
}

/// A search result returned by [ZimReader.searchFulltext].
class ZimSearchResult extends DictSearchResult {
  const ZimSearchResult({
    required super.article,
    required super.snippet,
    super.score = 1.0,
  });

  ZimEntry get zimEntry => article as ZimEntry;
}

/// Reader for ZIM archives (openZIM / Kiwix format).
///
/// Supports reading articles, images, media, metadata, and redirects from
/// compressed (Zstandard, LZMA2/XZ, Zlib) or uncompressed ZIM files.
///
/// ```dart
/// final reader = ZimReader('/path/to/wikipedia.zim');
/// await reader.init();
/// final entries = await reader.lookup('Albert Einstein');
/// if (entries.isNotEmpty) {
///   final html = await entries.first.readText();
/// }
/// ```
class ZimReader implements DictionaryReader {
  /// Path to the `.zim` file.
  final String path;

  ZimReader(this.path);

  @override
  Future<Uint8List?> getResource(String path) => readDataByPath(path);

  RandomAccessFile? _file;
  bool _initialized = false;
  bool _metadataInitialized = false;

  int _majorVersion = 0;
  int _minorVersion = 0;
  Uint8List _uuid = Uint8List(16);
  int _entryCount = 0;
  int _clusterCount = 0;
  int _pathPtrPos = 0;
  int _titlePtrPos = 0;
  int _clusterPtrPos = 0;
  int _mimeListPos = 0;
  int _mainPage = 0xffffffff;
  int _layoutPage = 0xffffffff;
  int _checksumPos = 0;

  List<String> _mimeTypes = [];
  Map<String, String> _metadata = {};

  Uint64List? _clusterOffsets;
  Uint64List? _pathPointers;
  Uint32List? _titlePointers;

  List<int> _articleIndices = [];
  List<String> _articleTitles = [];
  List<int> _searchOrder = [];
  Map<String, int> _titleToIndex = {};
  Map<String, int> _normalizedTitles = {};
  Map<String, int> _lowerTitles = {};
  Map<String, int> _pathToEntryIndex = {};

  // Cluster decompression cache
  final Map<int, Uint8List> _clusterCache = {};
  final List<int> _clusterLru = [];
  static const int _maxCachedClusters = 16;

  int get majorVersion => _majorVersion;
  int get minorVersion => _minorVersion;
  Uint8List get uuid => _uuid;
  String get uuidHex =>
      _uuid.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  int get entryCount => _entryCount;
  int get clusterCount => _clusterCount;
  int get mainPage => _mainPage;
  int get layoutPage => _layoutPage;
  int get checksumPos => _checksumPos;
  int get pathPtrPos => _pathPtrPos;
  int get titlePtrPos => _titlePtrPos;
  int get clusterPtrPos => _clusterPtrPos;
  int get mimeListPos => _mimeListPos;
  Uint32List? get titlePointers => _titlePointers;
  Uint64List? get pathPointers => _pathPointers;
  Uint64List? get clusterOffsets => _clusterOffsets;
  bool get hasTitleIndex =>
      _titlePtrPos != 0 && _titlePtrPos != 0xffffffffffffffff;

  List<String> get mimeTypes => List.unmodifiable(_mimeTypes);
  Map<String, String> get metadata => Map.unmodifiable(_metadata);

  String get bookName => title.isNotEmpty ? title : (metadata['Name'] ?? '');
  @override
  String get title => metadata['Title'] ?? '';
  String get description => metadata['Description'] ?? '';
  String get language => metadata['Language'] ?? '';
  String get creator => metadata['Creator'] ?? '';
  String get publisher => metadata['Publisher'] ?? '';
  String get date => metadata['Date'] ?? '';

  /// Total number of article headwords.
  @override
  int get wordCount => _articleIndices.length;

  /// All article headwords in sorted order.
  @override
  List<String> get words => List.unmodifiable(_articleTitles);

  /// Returns the headword of the [index]-th article.
  @override
  String wordAt(int index) => _articleTitles[index];

  /// Reads file header and MIME list without loading the full index.
  Future<void> initMetadata() async {
    if (_metadataInitialized) return;

    final f = await File(path).open(mode: FileMode.read);
    try {
      await f.setPosition(0);
      final headerBytes = await f.read(80);
      if (headerBytes.length < 80) {
        throw const FormatException('File too small to be a ZIM archive');
      }

      final bd = ByteData.sublistView(headerBytes);
      final magic = bd.getUint32(0, Endian.little);
      if (magic != 0x044D495A) {
        throw const FormatException('Not a ZIM file: invalid magic number');
      }

      _majorVersion = bd.getUint16(4, Endian.little);
      _minorVersion = bd.getUint16(6, Endian.little);
      _uuid = Uint8List.fromList(headerBytes.sublist(8, 24));
      _entryCount = bd.getUint32(24, Endian.little);
      _clusterCount = bd.getUint32(28, Endian.little);
      _pathPtrPos = bd.getUint64(32, Endian.little);
      _titlePtrPos = bd.getUint64(40, Endian.little);
      _clusterPtrPos = bd.getUint64(48, Endian.little);
      _mimeListPos = bd.getUint64(56, Endian.little);
      _mainPage = bd.getUint32(64, Endian.little);
      _layoutPage = bd.getUint32(68, Endian.little);
      _checksumPos = bd.getUint64(72, Endian.little);

      // Read MIME type list
      await f.setPosition(_mimeListPos);
      final mimeChunk = await f.read(4096);
      _mimeTypes = _parseMimeList(mimeChunk);
      _metadataInitialized = true;
    } finally {
      await f.close();
    }
  }

  /// Initializes the ZIM reader, parsing the index, pointer lists, and metadata.
  ///
  /// Set [useIsolate] to `true` (default) to run the index parsing in a background isolate.
  Future<void> init({bool useIsolate = true}) async {
    if (_initialized) return;

    await initMetadata();

    final parsed = useIsolate
        ? await Isolate.run(() => _parseZimIndex(path))
        : _parseZimIndex(path);

    _majorVersion = parsed.majorVersion;
    _minorVersion = parsed.minorVersion;
    _uuid = parsed.uuid;
    _entryCount = parsed.entryCount;
    _clusterCount = parsed.clusterCount;
    _pathPtrPos = parsed.pathPtrPos;
    _titlePtrPos = parsed.titlePtrPos;
    _clusterPtrPos = parsed.clusterPtrPos;
    _mimeListPos = parsed.mimeListPos;
    _mainPage = parsed.mainPage;
    _layoutPage = parsed.layoutPage;
    _checksumPos = parsed.checksumPos;
    _mimeTypes = parsed.mimeTypes;
    _metadata = parsed.metadata;
    _clusterOffsets = parsed.clusterOffsets;
    _pathPointers = parsed.pathPointers;
    _titlePointers = parsed.titlePointers;
    _articleIndices = parsed.articleIndices;
    _articleTitles = parsed.articleTitles;
    _searchOrder = parsed.searchOrder;
    _titleToIndex = parsed.titleToIndex;
    _normalizedTitles = parsed.normalizedTitles;
    _lowerTitles = parsed.lowerTitles;
    _pathToEntryIndex = parsed.pathToEntryIndex;

    _file = await File(path).open(mode: FileMode.read);
    _initialized = true;
  }

  /// Whether [word] exists as an article in this archive.
  @override
  bool exist(String word) => resolveIndex(word) != null;

  /// Resolves [word] to an entry index: exact title first, then normalized NFC,
  /// then lowercase, then path.
  int? resolveIndex(String word) {
    if (!_initialized) {
      throw StateError('ZimReader.init() has not completed');
    }

    // Exact title
    final exact = _titleToIndex[word];
    if (exact != null) return exact;

    // Normalised NFC spelling
    final nfc = normalizeKey(word);
    if (nfc != word) {
      final normIdx = _normalizedTitles[nfc];
      if (normIdx != null) return normIdx;
    }

    // Lowercase spelling
    final lower = word.toLowerCase();
    final lowerIdx = _lowerTitles[lower];
    if (lowerIdx != null) return lowerIdx;

    final lowerNfc = nfc.toLowerCase();
    if (lowerNfc != lower) {
      final lowerNfcIdx = _lowerTitles[lowerNfc];
      if (lowerNfcIdx != null) return lowerNfcIdx;
    }

    // Path match (e.g. if queried by path)
    return _pathToEntryIndex[word];
  }

  /// Looks up [word] and returns matching entries.
  ///
  /// When [followRedirects] is `true` (default), redirects are automatically
  /// followed to return the target content entry.
  @override
  Future<List<ZimEntry>> lookup(
    String word, {
    bool followRedirects = true,
  }) async {
    if (!_initialized) {
      throw StateError('ZimReader.init() has not completed');
    }

    final targetIndex = resolveIndex(word);
    if (targetIndex == null) return const [];

    final entry = await getEntry(targetIndex);
    if (!followRedirects || !entry.isRedirect) {
      return [entry];
    }

    // Follow redirect chain (up to 10 hops)
    var current = entry;
    var hops = 0;
    while (current.isRedirect && current.redirectIndex != null && hops < 10) {
      final nextIdx = current.redirectIndex!;
      if (nextIdx >= 0 && nextIdx < _entryCount) {
        current = await getEntry(nextIdx);
        hops++;
      } else {
        break;
      }
    }

    return [
      ZimEntry(
        index: current.index,
        namespace: current.namespace,
        path: current.path,
        title: current.title,
        mimeType: current.mimeType,
        isRedirect: current.isRedirect,
        redirectIndex: current.redirectIndex,
        clusterNumber: current.clusterNumber,
        blobNumber: current.blobNumber,
        reader: this,
        resolvedFrom: word,
      ),
    ];
  }

  /// Prefix search over article headwords/titles, case-insensitive and NFC-normalised,
  /// returning at most [limit] suggestions.
  @override
  List<String> search(String query, {int? limit = 30}) {
    if (!_initialized) {
      throw StateError('ZimReader.init() has not completed');
    }
    if (query.isEmpty) return const [];
    final maxResults = limit ?? 30;

    final lowerQuery = normalizeKey(query).toLowerCase();

    // Binary search over _searchOrder
    var lo = 0;
    var hi = _searchOrder.length;
    while (lo < hi) {
      final mid = (lo + hi) >> 1;
      final probe =
          normalizeKey(_articleTitles[_searchOrder[mid]]).toLowerCase();
      if (probe.compareTo(lowerQuery) < 0) {
        lo = mid + 1;
      } else {
        hi = mid;
      }
    }

    final results = <String>[];
    final seen = <String>{};
    for (var i = lo;
        i < _searchOrder.length && results.length < maxResults;
        i++) {
      final title = _articleTitles[_searchOrder[i]];
      final norm = normalizeKey(title).toLowerCase();
      if (!norm.startsWith(lowerQuery)) break;
      if (seen.add(title)) {
        results.add(title);
      }
    }
    return results;
  }

  /// Whether this archive contains an embedded Xapian full-text search index (in namespace 'X').
  bool get hasFulltextIndex {
    return _pathToEntryIndex.containsKey('X/fulltext/xapian') ||
        _pathToEntryIndex.keys.any((k) => k.startsWith('X/fulltext/xapian'));
  }

  /// Returns all entries located in the index/search namespace 'X'.
  List<String> get fulltextIndexPaths {
    return _pathToEntryIndex.keys.where((k) => k.startsWith('X/')).toList();
  }

  /// Extracts the embedded Xapian full-text database files into [targetDir].
  Future<void> extractFulltextDatabase(Directory targetDir) async {
    if (!targetDir.existsSync()) {
      await targetDir.create(recursive: true);
    }
    for (final e in _pathToEntryIndex.entries) {
      if (e.key.startsWith('X/fulltext/xapian')) {
        final rel = e.key.substring('X/fulltext/xapian'.length);
        final cleanRel = rel.startsWith('/') ? rel.substring(1) : rel;
        final targetPath = cleanRel.isEmpty
            ? '${targetDir.path}/fulltext.xapian'
            : '${targetDir.path}/$cleanRel';
        final entry = await getEntry(e.value);
        final data = await entry.readData();
        final outFile = File(targetPath);
        await outFile.parent.create(recursive: true);
        await outFile.writeAsBytes(data);
      }
    }
  }

  @override
  Future<List<ZimSearchResult>> searchFulltext(
    String query, {
    int limit = 20,
  }) async {
    if (!_initialized) {
      throw StateError('ZimReader.init() has not completed');
    }
    if (query.isEmpty) return const [];

    final lowerQuery = normalizeKey(query).toLowerCase();
    final results = <ZimSearchResult>[];
    final seen = <int>{};

    // 1. Title match phase (highest relevance)
    for (var i = 0; i < _articleTitles.length && results.length < limit; i++) {
      final title = _articleTitles[i];
      if (title.toLowerCase().contains(lowerQuery)) {
        final entryIdx = _articleIndices[i];
        if (seen.add(entryIdx)) {
          final entry = await getEntry(entryIdx);
          final text = await entry.readText();
          final snippet = extractSnippet(text, query);
          results.add(ZimSearchResult(
            article: entry,
            snippet: snippet,
            score: title.toLowerCase() == lowerQuery ? 3.0 : 2.0,
          ));
        }
      }
    }

    // 2. Article content scan phase (for remaining slots)
    if (results.length < limit) {
      for (var i = 0;
          i < _articleIndices.length && results.length < limit;
          i++) {
        final entryIdx = _articleIndices[i];
        if (seen.contains(entryIdx)) continue;

        final entry = await getEntry(entryIdx);
        final text = await entry.readText();
        if (text.toLowerCase().contains(lowerQuery)) {
          seen.add(entryIdx);
          final snippet = extractSnippet(text, query);
          results.add(ZimSearchResult(
            article: entry,
            snippet: snippet,
            score: 1.0,
          ));
        }
      }
    }

    results.sort((a, b) => b.score.compareTo(a.score));
    return results;
  }

  /// Retrieves an entry by its direct entry index (0 to [entryCount] - 1).
  Future<ZimEntry> getEntry(int index) async {
    if (!_initialized || _file == null) {
      throw StateError('ZimReader.init() has not completed');
    }
    if (index < 0 || index >= _entryCount) {
      throw RangeError.range(index, 0, _entryCount - 1, 'entry index');
    }

    final offset = _pathPointers![index];
    await _file!.setPosition(offset);

    // Read initial 256 bytes for dirent
    var buffer = await _file!.read(256);
    var parsed = _tryParseDirent(buffer, index);
    if (parsed == null) {
      // Need a larger buffer for long path/title
      await _file!.setPosition(offset);
      buffer = await _file!.read(2048);
      parsed = _tryParseDirent(buffer, index);
      if (parsed == null) {
        throw FormatException(
            'Failed to parse directory entry at offset $offset');
      }
    }

    final mime = parsed.isRedirect
        ? 'application/x-zim-redirect'
        : (parsed.mimeTypeIndex < _mimeTypes.length
            ? _mimeTypes[parsed.mimeTypeIndex]
            : 'application/octet-stream');

    return ZimEntry(
      index: index,
      namespace: parsed.namespace,
      path: parsed.path,
      title: parsed.title,
      mimeType: mime,
      isRedirect: parsed.isRedirect,
      redirectIndex: parsed.redirectIndex,
      clusterNumber: parsed.clusterNumber,
      blobNumber: parsed.blobNumber,
      reader: this,
    );
  }

  /// Looks up a resource or article by its path (e.g. "I/photo.png", "apple",
  /// or relative "../I/photo.png").
  Future<ZimEntry?> getEntryByPath(
    String rawPath, {
    String? currentNamespace,
  }) async {
    if (!_initialized) {
      throw StateError('ZimReader.init() has not completed');
    }

    final normalized = _normalizePath(rawPath);
    var targetIdx = _pathToEntryIndex[normalized];

    if (targetIdx == null && currentNamespace != null) {
      targetIdx = _pathToEntryIndex['$currentNamespace/$normalized'];
    }

    if (targetIdx == null) {
      try {
        final decoded = Uri.decodeFull(normalized);
        if (decoded != normalized) {
          targetIdx = _pathToEntryIndex[decoded];
          if (targetIdx == null && currentNamespace != null) {
            targetIdx = _pathToEntryIndex['$currentNamespace/$decoded'];
          }
        }
      } catch (_) {}
    }

    if (targetIdx == null) return null;
    return getEntry(targetIdx);
  }

  /// Reads the raw data bytes for a resource at [rawPath].
  Future<Uint8List?> readDataByPath(
    String rawPath, {
    String? currentNamespace,
  }) async {
    final entry = await getEntryByPath(
      rawPath,
      currentNamespace: currentNamespace,
    );
    if (entry == null) return null;
    return entry.readData();
  }

  /// Returns the entry for the archive's main page, or null if none is declared.
  Future<ZimEntry?> getMainPageEntry() async {
    if (_mainPage == 0xffffffff) return null;
    return getEntry(_mainPage);
  }

  /// Reads a blob from a cluster, decompressing the cluster on demand and caching it.
  Future<Uint8List> readBlob(int clusterNumber, int blobNumber) async {
    if (!_initialized || _file == null) {
      throw StateError('ZimReader.init() has not completed');
    }
    if (clusterNumber < 0 || clusterNumber >= _clusterCount) {
      throw RangeError.range(
        clusterNumber,
        0,
        _clusterCount - 1,
        'clusterNumber',
      );
    }

    final decompressed = await _getDecompressedCluster(clusterNumber);
    final isExtended = _isClusterExtended(clusterNumber);
    return _extractBlob(decompressed, blobNumber, isExtended);
  }

  /// Opens a byte stream for reading the blob at [clusterNumber], [blobNumber],
  /// optionally constrained to the range [start] (inclusive) up to [end] (exclusive).
  ///
  /// For uncompressed clusters, this streams directly from the disk file without
  /// reading the entire cluster into memory.
  Future<Stream<List<int>>> readBlobStream(
    int clusterNumber,
    int blobNumber, {
    int? start,
    int? end,
  }) async {
    if (!_initialized || _file == null) {
      throw StateError('ZimReader.init() has not completed');
    }
    if (clusterNumber < 0 || clusterNumber >= _clusterCount) {
      throw RangeError.range(
        clusterNumber,
        0,
        _clusterCount - 1,
        'clusterNumber',
      );
    }

    final clusterOffset = _clusterOffsets![clusterNumber];
    await _file!.setPosition(clusterOffset);
    final infoBytes = await _file!.read(1);
    if (infoBytes.isEmpty) {
      throw FormatException('Empty cluster $clusterNumber');
    }
    final infoByte = infoBytes[0];
    final compType = infoByte & 0x0f;
    final isExtended = (infoByte & 0x10) != 0;

    if (compType <= 1) {
      // Uncompressed cluster! Stream directly from disk.
      final offsetSize = isExtended ? 8 : 4;
      await _file!.setPosition(clusterOffset + 1);
      final offset0Bytes = await _file!.read(offsetSize);
      final bd = ByteData.sublistView(offset0Bytes);
      final offset0 = isExtended
          ? bd.getUint64(0, Endian.little)
          : bd.getUint32(0, Endian.little);
      final totalOffsets = offset0 ~/ offsetSize;
      final totalBlobs = totalOffsets - 1;
      if (blobNumber < 0 || blobNumber >= totalBlobs) {
        throw RangeError.range(blobNumber, 0, totalBlobs - 1, 'blobNumber');
      }

      await _file!.setPosition(clusterOffset + 1 + blobNumber * offsetSize);
      final pairBytes = await _file!.read(offsetSize * 2);
      final pairBd = ByteData.sublistView(pairBytes);
      final blobStart = isExtended
          ? pairBd.getUint64(0, Endian.little)
          : pairBd.getUint32(0, Endian.little);
      final blobEnd = isExtended
          ? pairBd.getUint64(offsetSize, Endian.little)
          : pairBd.getUint32(offsetSize, Endian.little);

      final blobLength = blobEnd - blobStart;
      final s = (start ?? 0).clamp(0, blobLength);
      final e = (end ?? blobLength).clamp(s, blobLength);
      if (s >= e) return Stream.value(Uint8List(0));

      final diskStart = clusterOffset + 1 + blobStart + s;
      final diskEnd = clusterOffset + 1 + blobStart + e;
      return File(path).openRead(diskStart, diskEnd);
    } else {
      final decompressed = await _getDecompressedCluster(clusterNumber);
      final blob = _extractBlob(decompressed, blobNumber, isExtended);
      final length = blob.length;
      final s = (start ?? 0).clamp(0, length);
      final e = (end ?? length).clamp(s, length);
      if (s >= e) return Stream.value(Uint8List(0));
      return Stream.value(Uint8List.sublistView(blob, s, e));
    }
  }

  @override
  Future<Stream<List<int>>?> getResourceStream(
    String path, {
    int? start,
    int? end,
  }) async {
    final entry = await getEntryByPath(path);
    if (entry == null) return null;
    return entry.openRead(start: start, end: end);
  }

  @override
  Future<Uint8List> exportCidx() async {
    if (!_initialized) {
      throw StateError('ZimReader.init() has not completed');
    }
    final file = File(path);
    final stat = await file.stat();
    return serializeZimCidx(
      filePath: path,
      fileSize: stat.size,
      fileModified: stat.modified.microsecondsSinceEpoch,
      majorVersion: _majorVersion,
      minorVersion: _minorVersion,
      uuid: _uuid,
      entryCount: _entryCount,
      clusterCount: _clusterCount,
      pathPtrPos: _pathPtrPos,
      titlePtrPos: _titlePtrPos,
      clusterPtrPos: _clusterPtrPos,
      mimeListPos: _mimeListPos,
      mainPage: _mainPage,
      layoutPage: _layoutPage,
      checksumPos: _checksumPos,
      mimeTypes: _mimeTypes,
      metadata: _metadata,
      clusterOffsets: _clusterOffsets!,
      pathPointers: _pathPointers!,
      titlePointers: _titlePointers,
      articleIndices: _articleIndices,
      articleTitles: _articleTitles,
      searchOrder: _searchOrder,
      pathToEntryIndex: _pathToEntryIndex,
    );
  }

  @override
  Future<void> importCidx(Uint8List bytes) async {
    final targetFile = File(path);
    final deserialized = deserializeZimCidx(bytes, targetFile);

    _majorVersion = deserialized.majorVersion;
    _minorVersion = deserialized.minorVersion;
    _uuid = deserialized.uuid;
    _entryCount = deserialized.entryCount;
    _clusterCount = deserialized.clusterCount;
    _pathPtrPos = deserialized.pathPtrPos;
    _titlePtrPos = deserialized.titlePtrPos;
    _clusterPtrPos = deserialized.clusterPtrPos;
    _mimeListPos = deserialized.mimeListPos;
    _mainPage = deserialized.mainPage;
    _layoutPage = deserialized.layoutPage;
    _checksumPos = deserialized.checksumPos;
    _mimeTypes = deserialized.mimeTypes;
    _metadata = deserialized.metadata;
    _clusterOffsets = deserialized.clusterOffsets;
    _pathPointers = deserialized.pathPointers;
    _titlePointers = deserialized.titlePointers;
    _articleIndices = deserialized.articleIndices;
    _articleTitles = deserialized.articleTitles;
    _searchOrder = deserialized.searchOrder;
    _pathToEntryIndex = deserialized.pathToEntryIndex;

    _titleToIndex.clear();
    _normalizedTitles.clear();
    _lowerTitles.clear();
    for (var i = 0; i < _articleTitles.length; i++) {
      final title = _articleTitles[i];
      final entryIdx = _articleIndices[i];
      _titleToIndex.putIfAbsent(title, () => entryIdx);
      final norm = normalizeKey(title);
      _normalizedTitles.putIfAbsent(norm, () => entryIdx);
      _lowerTitles.putIfAbsent(title.toLowerCase(), () => entryIdx);
      _lowerTitles.putIfAbsent(norm.toLowerCase(), () => entryIdx);
    }

    _file = await targetFile.open(mode: FileMode.read);
    _initialized = true;
    _metadataInitialized = true;
  }

  bool _isClusterExtended(int clusterNumber) {
    // Info byte bit 4 determines extension
    final info = _clusterInfoCache[clusterNumber];
    if (info != null) return (info & 0x10) != 0;
    return false;
  }

  final Map<int, int> _clusterInfoCache = {};

  Future<Uint8List> _getDecompressedCluster(int clusterNumber) async {
    final cached = _clusterCache[clusterNumber];
    if (cached != null) {
      _clusterLru.remove(clusterNumber);
      _clusterLru.add(clusterNumber);
      return cached;
    }

    final offset = _clusterOffsets![clusterNumber];
    final int nextOffset;
    if (clusterNumber + 1 < _clusterCount) {
      nextOffset = _clusterOffsets![clusterNumber + 1];
    } else {
      final fileLen = await _file!.length();
      nextOffset = (_checksumPos > 0 && _checksumPos <= fileLen)
          ? _checksumPos
          : fileLen;
    }

    final compressedSize = nextOffset - offset;
    if (compressedSize <= 0) {
      throw FormatException('Invalid cluster size for cluster $clusterNumber');
    }

    await _file!.setPosition(offset);
    final clusterData = await _file!.read(compressedSize);
    if (clusterData.isEmpty) {
      throw FormatException('Empty cluster $clusterNumber');
    }

    final infoByte = clusterData[0];
    _clusterInfoCache[clusterNumber] = infoByte;
    final decompressed = _decompressCluster(clusterData);

    // Add to LRU cache
    if (_clusterCache.length >= _maxCachedClusters) {
      final oldest = _clusterLru.removeAt(0);
      _clusterCache.remove(oldest);
    }
    _clusterCache[clusterNumber] = decompressed;
    _clusterLru.add(clusterNumber);

    return decompressed;
  }

  /// Closes the underlying file and releases memory caches.
  @override
  Future<void> close() async {
    await _file?.close();
    _file = null;
    _clusterCache.clear();
    _clusterLru.clear();
    _clusterInfoCache.clear();
    _initialized = false;
    _metadataInitialized = false;
  }
}

/// Normalizes a path string (removes leading slashes, resolves `.` and `..`).
String _normalizePath(String raw) {
  var p = raw.replaceAll('\\', '/');
  while (p.startsWith('/')) {
    p = p.substring(1);
  }
  final segments = <String>[];
  for (final part in p.split('/')) {
    if (part.isEmpty || part == '.') continue;
    if (part == '..') {
      if (segments.isNotEmpty) segments.removeLast();
    } else {
      segments.add(part);
    }
  }
  return segments.join('/');
}

List<String> _parseMimeList(Uint8List bytes) {
  final list = <String>[];
  var pos = 0;
  while (pos < bytes.length) {
    final end = bytes.indexOf(0, pos);
    if (end < 0) break;
    if (end == pos) break; // Double zero marks end of MIME list
    final mime = utf8.decode(
      Uint8List.sublistView(bytes, pos, end),
      allowMalformed: true,
    );
    list.add(mime);
    pos = end + 1;
  }
  return list;
}

Uint8List _decompressCluster(Uint8List clusterData) {
  if (clusterData.isEmpty) {
    throw const FormatException('Empty cluster data');
  }
  final infoByte = clusterData[0];
  final compType = infoByte & 0x0f;
  final payload = Uint8List.sublistView(clusterData, 1);

  switch (compType) {
    case 0:
    case 1:
      return payload;
    case 2:
      return Uint8List.fromList(zlib.decode(payload));
    case 4:
      return XZDecoder().decodeBytes(payload);
    case 5:
      return ZstdDecoder().decodeBytes(payload);
    default:
      throw UnsupportedCompressionException(compType);
  }
}

Uint8List _extractBlob(
    Uint8List uncompressed, int blobNumber, bool isExtended) {
  final bd = ByteData.sublistView(uncompressed);
  final int offsetSize = isExtended ? 8 : 4;
  final int offset0 = isExtended
      ? bd.getUint64(0, Endian.little)
      : bd.getUint32(0, Endian.little);

  final totalOffsets = offset0 ~/ offsetSize;
  final totalBlobs = totalOffsets - 1;

  if (blobNumber < 0 || blobNumber >= totalBlobs) {
    throw RangeError.range(blobNumber, 0, totalBlobs - 1, 'blobNumber');
  }

  final int blobStart = isExtended
      ? bd.getUint64(blobNumber * 8, Endian.little)
      : bd.getUint32(blobNumber * 4, Endian.little);
  final int blobEnd = isExtended
      ? bd.getUint64((blobNumber + 1) * 8, Endian.little)
      : bd.getUint32((blobNumber + 1) * 4, Endian.little);

  if (blobStart < 0 || blobEnd > uncompressed.length || blobStart > blobEnd) {
    throw FormatException(
      'Invalid blob offsets in cluster: $blobStart..$blobEnd',
    );
  }

  return Uint8List.sublistView(uncompressed, blobStart, blobEnd);
}

class _RawDirent {
  final int mimeTypeIndex;
  final String namespace;
  final int revision;
  final bool isRedirect;
  final int? redirectIndex;
  final int clusterNumber;
  final int blobNumber;
  final String path;
  final String title;
  final int totalLength;

  _RawDirent({
    required this.mimeTypeIndex,
    required this.namespace,
    required this.revision,
    required this.isRedirect,
    this.redirectIndex,
    required this.clusterNumber,
    required this.blobNumber,
    required this.path,
    required this.title,
    required this.totalLength,
  });
}

_RawDirent? _tryParseDirent(Uint8List bytes, int entryIndex) {
  if (bytes.length < 12) return null;

  final bd = ByteData.sublistView(bytes);
  final mimeType = bd.getUint16(0, Endian.little);
  final extraLen = bd.getUint8(2);
  final ns = String.fromCharCode(bd.getUint8(3));
  final revision = bd.getUint32(4, Endian.little);
  final isRedirect = (mimeType == 0xffff);

  int? redirectIndex;
  int clusterNumber = 0;
  int blobNumber = 0;
  int pos;

  if (isRedirect) {
    redirectIndex = bd.getUint32(8, Endian.little);
    pos = 12;
  } else if (mimeType == 0xfffe || mimeType == 0xfffd) {
    pos = 8;
  } else {
    if (bytes.length < 16) return null;
    clusterNumber = bd.getUint32(8, Endian.little);
    blobNumber = bd.getUint32(12, Endian.little);
    pos = 16;
  }

  final pathEnd = bytes.indexOf(0, pos);
  if (pathEnd < 0) return null;
  final path = utf8.decode(
    Uint8List.sublistView(bytes, pos, pathEnd),
    allowMalformed: true,
  );
  pos = pathEnd + 1;

  final titleEnd = bytes.indexOf(0, pos);
  if (titleEnd < 0) return null;
  var title = utf8.decode(
    Uint8List.sublistView(bytes, pos, titleEnd),
    allowMalformed: true,
  );
  if (title.isEmpty) {
    title = path;
  }
  pos = titleEnd + 1;
  pos += extraLen;

  return _RawDirent(
    mimeTypeIndex: mimeType,
    namespace: ns,
    revision: revision,
    isRedirect: isRedirect,
    redirectIndex: redirectIndex,
    clusterNumber: clusterNumber,
    blobNumber: blobNumber,
    path: path,
    title: title,
    totalLength: pos,
  );
}

class _ParsedZimIndex {
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
  final Map<String, int> titleToIndex;
  final Map<String, int> normalizedTitles;
  final Map<String, int> lowerTitles;
  final Map<String, int> pathToEntryIndex;

  _ParsedZimIndex({
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
    required this.titleToIndex,
    required this.normalizedTitles,
    required this.lowerTitles,
    required this.pathToEntryIndex,
  });
}

_ParsedZimIndex _parseZimIndex(String filePath) {
  final f = File(filePath).openSync(mode: FileMode.read);
  try {
    f.setPositionSync(0);
    final headerBytes = f.readSync(80);
    if (headerBytes.length < 80) {
      throw const FormatException('File too small to be a ZIM archive');
    }

    final bd = ByteData.sublistView(headerBytes);
    final magic = bd.getUint32(0, Endian.little);
    if (magic != 0x044D495A) {
      throw const FormatException('Not a ZIM file: invalid magic number');
    }

    final majorVersion = bd.getUint16(4, Endian.little);
    final minorVersion = bd.getUint16(6, Endian.little);
    final uuid = Uint8List.fromList(headerBytes.sublist(8, 24));
    final entryCount = bd.getUint32(24, Endian.little);
    final clusterCount = bd.getUint32(28, Endian.little);
    final pathPtrPos = bd.getUint64(32, Endian.little);
    final titlePtrPos = bd.getUint64(40, Endian.little);
    final clusterPtrPos = bd.getUint64(48, Endian.little);
    final mimeListPos = bd.getUint64(56, Endian.little);
    final mainPage = bd.getUint32(64, Endian.little);
    final layoutPage = bd.getUint32(68, Endian.little);
    final checksumPos = bd.getUint64(72, Endian.little);

    // Read MIME type list
    f.setPositionSync(mimeListPos);
    final mimeChunk = f.readSync(4096);
    final mimeTypes = _parseMimeList(mimeChunk);

    // Read cluster pointers
    f.setPositionSync(clusterPtrPos);
    final clusterPtrBytes = f.readSync(clusterCount * 8);
    final clusterOffsets = Uint64List(clusterCount);
    final clusterBd = ByteData.sublistView(clusterPtrBytes);
    for (var i = 0; i < clusterCount; i++) {
      clusterOffsets[i] = clusterBd.getUint64(i * 8, Endian.little);
    }

    // Read path pointers
    f.setPositionSync(pathPtrPos);
    final pathPtrBytes = f.readSync(entryCount * 8);
    final pathPointers = Uint64List(entryCount);
    final pathBd = ByteData.sublistView(pathPtrBytes);
    for (var i = 0; i < entryCount; i++) {
      pathPointers[i] = pathBd.getUint64(i * 8, Endian.little);
    }

    // Read title pointers if present
    Uint32List? titlePointers;
    if (titlePtrPos != 0 && titlePtrPos != 0xffffffffffffffff) {
      f.setPositionSync(titlePtrPos);
      final titlePtrBytes = f.readSync(entryCount * 4);
      titlePointers = Uint32List(entryCount);
      final titleBd = ByteData.sublistView(titlePtrBytes);
      for (var i = 0; i < entryCount; i++) {
        titlePointers[i] = titleBd.getUint32(i * 4, Endian.little);
      }
    }

    // Read and parse all directory entries
    // Usually directory entries are stored contiguously before pathPtrPos.
    final firstEntryOffset = entryCount > 0 ? pathPointers[0] : 0;
    final lastEntryOffset = entryCount > 0 ? pathPointers[entryCount - 1] : 0;
    Uint8List? contiguousBuffer;

    if (entryCount > 0 &&
        lastEntryOffset >= firstEntryOffset &&
        (lastEntryOffset - firstEntryOffset) < 100 * 1024 * 1024) {
      final totalSpan = (lastEntryOffset - firstEntryOffset) + 4096;
      f.setPositionSync(firstEntryOffset);
      contiguousBuffer = f.readSync(totalSpan);
    }

    final articleIndices = <int>[];
    final articleTitles = <String>[];
    final titleToIndex = <String, int>{};
    final normalizedTitles = <String, int>{};
    final lowerTitles = <String, int>{};
    final pathToEntryIndex = <String, int>{};
    final metadataEntries = <(String key, int cluster, int blob)>[];

    for (var i = 0; i < entryCount; i++) {
      final offset = pathPointers[i];
      _RawDirent? dirent;

      if (contiguousBuffer != null) {
        final rel = offset - firstEntryOffset;
        if (rel >= 0 && rel < contiguousBuffer.length) {
          dirent = _tryParseDirent(
            Uint8List.sublistView(contiguousBuffer, rel),
            i,
          );
        }
      }

      if (dirent == null) {
        f.setPositionSync(offset);
        final buf = f.readSync(256);
        dirent = _tryParseDirent(buf, i);
        if (dirent == null) {
          f.setPositionSync(offset);
          dirent = _tryParseDirent(f.readSync(2048), i);
        }
      }

      if (dirent == null) continue;

      final fullPath = '${dirent.namespace}/${dirent.path}';
      pathToEntryIndex[dirent.path] = i;
      pathToEntryIndex[fullPath] = i;

      if (dirent.namespace == 'M') {
        metadataEntries
            .add((dirent.path, dirent.clusterNumber, dirent.blobNumber));
        continue;
      }

      final mime = dirent.isRedirect
          ? 'application/x-zim-redirect'
          : (dirent.mimeTypeIndex < mimeTypes.length
              ? mimeTypes[dirent.mimeTypeIndex]
              : '');

      final isArticle = dirent.namespace == 'A' ||
          (dirent.namespace == 'C' &&
              (mime.startsWith('text/') || dirent.isRedirect)) ||
          (dirent.namespace != 'I' &&
              dirent.namespace != '-' &&
              dirent.namespace != 'W' &&
              dirent.namespace != 'X' &&
              (mime.startsWith('text/') || dirent.isRedirect));

      if (isArticle) {
        articleIndices.add(i);
        articleTitles.add(dirent.title);

        titleToIndex.putIfAbsent(dirent.title, () => i);
        final nfc = normalizeKey(dirent.title);
        if (nfc != dirent.title) {
          normalizedTitles.putIfAbsent(nfc, () => i);
        }
        lowerTitles.putIfAbsent(dirent.title.toLowerCase(), () => i);
        if (nfc != dirent.title) {
          lowerTitles.putIfAbsent(nfc.toLowerCase(), () => i);
        }
      }
    }

    // Search order: indices into articleTitles, sorted by lowercase NFC title
    final searchOrder = List<int>.generate(articleTitles.length, (i) => i)
      ..sort((a, b) {
        final ta = normalizeKey(articleTitles[a]).toLowerCase();
        final tb = normalizeKey(articleTitles[b]).toLowerCase();
        return ta.compareTo(tb);
      });

    // Read metadata blobs
    final metadata = <String, String>{};
    for (final (key, cluster, blob) in metadataEntries) {
      try {
        if (cluster < clusterOffsets.length) {
          final cOffset = clusterOffsets[cluster];
          final int nextOffset;
          if (cluster + 1 < clusterOffsets.length) {
            nextOffset = clusterOffsets[cluster + 1];
          } else {
            final fileLen = f.lengthSync();
            nextOffset = (checksumPos > 0 && checksumPos <= fileLen)
                ? checksumPos
                : fileLen;
          }
          final cSize = nextOffset - cOffset;
          if (cSize > 0) {
            f.setPositionSync(cOffset);
            final cBytes = f.readSync(cSize);
            final decomp = _decompressCluster(cBytes);
            final isExtended = (cBytes[0] & 0x10) != 0;
            final blobData = _extractBlob(decomp, blob, isExtended);
            metadata[key] = utf8.decode(blobData, allowMalformed: true);
          }
        }
      } catch (_) {}
    }

    return _ParsedZimIndex(
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
      titleToIndex: titleToIndex,
      normalizedTitles: normalizedTitles,
      lowerTitles: lowerTitles,
      pathToEntryIndex: pathToEntryIndex,
    );
  } finally {
    f.closeSync();
  }
}
