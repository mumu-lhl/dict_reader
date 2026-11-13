import 'dart:async';
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
  ///
  /// Redirect entries resolve to their target first (up to 10 hops, mirroring
  /// [ZimReader.lookup]): a redirect carries no blob of its own, so reading
  /// its cluster/blob fields would return an unrelated entry's bytes.
  @override
  Future<Uint8List> readData() async {
    final target = await _resolveTarget();
    return target.reader.readBlob(target.clusterNumber, target.blobNumber);
  }

  /// Reads the entry data decoded as text.
  @override
  Future<String> readText([Encoding encoding = utf8]) async {
    final bytes = await readData();
    return encoding.decode(bytes);
  }

  /// Opens a byte stream for reading this entry's blob, optionally constrained
  /// to the byte range [start] (inclusive) up to [end] (exclusive).
  @override
  Future<Stream<List<int>>> openRead({int? start, int? end}) async {
    final target = await _resolveTarget();
    return target.reader.readBlobStream(
      target.clusterNumber,
      target.blobNumber,
      start: start,
      end: end,
    );
  }

  /// Follows the redirect chain starting at this entry, up to 10 hops.
  /// Returns this entry unchanged when it is not a redirect. Throws a
  /// [StateError] when the chain cannot be resolved to a content entry.
  Future<ZimEntry> _resolveTarget() async {
    var current = this;
    var hops = 0;
    while (current.isRedirect && current.redirectIndex != null && hops < 10) {
      final nextIdx = current.redirectIndex!;
      if (nextIdx < 0 || nextIdx >= current.reader._entryCount) break;
      current = await current.reader.getEntry(nextIdx);
      hops++;
    }
    if (current.isRedirect) {
      throw StateError(
        'Redirect chain for ${current.fullPath} could not be resolved',
      );
    }
    return current;
  }

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

/// One entry of [ZimReader]'s cluster cache: the decompressed cluster
/// bytes plus the info byte read from the cluster header.
class _CachedCluster {
  final Uint8List bytes;
  final int infoByte;

  const _CachedCluster(this.bytes, this.infoByte);
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

  /// Serializes every operation that touches the shared [_file] handle.
  /// Dart's [RandomAccessFile] throws `FileSystemException: An async operation
  /// is currently pending` when a second `setPosition`/`read` starts while
  /// another is in flight, and the handle's position is shared state — so
  /// concurrent lookups and resource loads must never interleave on it. The
  /// lock is a future chain: each holder awaits its predecessor and completes
  /// its own link on release, so an action that throws still unblocks the
  /// next waiter.
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

  /// Lowercase NFC sort keys, parallel to [_searchOrder]: element `k` is
  /// `normalizeKey(articleTitles[_searchOrder[k]]).toLowerCase()`.
  /// Sorted ascending; lowercase lookups binary-search this list instead of
  /// keeping a second lowercased map per title.
  List<String> _searchLowerKeys = [];
  Map<String, int> _titleToIndex = {};
  Map<String, int> _normalizedTitles = {};

  /// Canonical path index: one entry per dirent, keyed by full `ns/path`
  /// only (previously both the bare path and `ns/path` were stored, doubling
  /// the map). Bare-path callers resolve through [_resolvePathIndex], which
  /// derives `ns/path` candidates from the namespaces below.
  Map<String, int> _pathToEntryIndex = {};

  /// Distinct namespaces present in the archive, in first-appearance
  /// (dirent) order. Bare-path lookups try them in reverse order, mirroring
  /// the old last-wins behaviour of the dual-keyed map on spec-sorted
  /// archives (dirents are grouped by namespace, so the last writer was the
  /// highest namespace).
  List<String> _namespaces = [];

  // Cluster decompression cache: byte-capped LRU, keyed by cluster number.
  // Each entry holds the decompressed bytes plus the cluster info byte
  // (compression type + extended flag), so no separate info-byte map is
  // needed. [_clusterLru] lists cached clusters oldest first; a hit moves
  // its cluster to the end. [_clusterCacheBytes] tracks the total
  // decompressed size so eviction can enforce [_maxClusterCacheBytes].
  final Map<int, _CachedCluster> _clusterCache = {};
  final List<int> _clusterLru = [];
  int _clusterCacheBytes = 0;
  static const int _maxClusterCacheBytes = 32 * 1024 * 1024;

  /// Cluster numbers currently in the decompression cache, oldest first.
  /// Exposed so tests can assert on LRU eviction behaviour.
  List<int> get cachedClusterOrder => List.unmodifiable(_clusterLru);

  /// Total decompressed bytes currently held in the cluster cache.
  int get cachedClusterBytes => _clusterCacheBytes;

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

  /// Returns the title of the entry at [entryIndex], or `null` when that
  /// entry is not an article (e.g. a resource or metadata entry).
  ///
  /// Purely in-memory: [_articleIndices] is built in ascending entry order
  /// during index parsing, so a binary search finds the article slot
  /// without touching the disk. Throws [StateError] before [init] and
  /// [RangeError] for an out-of-range [entryIndex], like [getEntry].
  String? entryTitleAt(int entryIndex) {
    if (!_initialized) {
      throw StateError('ZimReader.init() has not completed');
    }
    if (entryIndex < 0 || entryIndex >= _entryCount) {
      throw RangeError.range(entryIndex, 0, _entryCount - 1, 'entry index');
    }
    var lo = 0;
    var hi = _articleIndices.length;
    while (lo < hi) {
      final mid = (lo + hi) >> 1;
      final value = _articleIndices[mid];
      if (value < entryIndex) {
        lo = mid + 1;
      } else if (value > entryIndex) {
        hi = mid;
      } else {
        return _articleTitles[mid];
      }
    }
    return null;
  }

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
      if (_majorVersion < 6) {
        throw FormatException(
          'Unsupported ZIM version $_majorVersion.$_minorVersion: '
          'only 6.x archives are supported',
        );
      }
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
  /// [direntWindowBytes] sizes the sliding window used to read directory
  /// entries (default 16 MiB); it is a testing knob for exercising the
  /// windowed path with small values.
  Future<void> init({bool useIsolate = true, int? direntWindowBytes}) async {
    if (_initialized) return;

    await initMetadata();

    // Copy the path to a local: the isolate closure must not capture `this`
    // (the reader holds unsendable state such as the file-access lock future,
    // and Isolate.run rejects the whole object graph when it does).
    final filePath = path;
    final windowBytes = direntWindowBytes ?? _defaultDirentWindowBytes;
    final parsed = useIsolate
        ? await Isolate.run(
            () => _parseZimIndex(
              filePath,
              direntWindowBytes: windowBytes,
            ),
          )
        : _parseZimIndex(filePath, direntWindowBytes: windowBytes);

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
    _searchLowerKeys = parsed.searchLowerKeys;
    _titleToIndex = parsed.titleToIndex;
    _normalizedTitles = parsed.normalizedTitles;
    _pathToEntryIndex = parsed.pathToEntryIndex;
    _namespaces = parsed.namespaces;

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

    // Lowercase spelling: binary-search the precomputed lowercase sort keys.
    // [_searchLowerKeys] is sorted in [_searchOrder] order, and the sort
    // breaks key ties by article position, so the leftmost match is the
    // first article in title order — the same winner the old
    // putIfAbsent map produced for duplicate lowercase keys.
    final lower = word.toLowerCase();
    final lowerIdx = _lowerBoundSearchKey(lower);
    if (lowerIdx != null) return lowerIdx;

    final lowerNfc = nfc.toLowerCase();
    if (lowerNfc != lower) {
      final lowerNfcIdx = _lowerBoundSearchKey(lowerNfc);
      if (lowerNfcIdx != null) return lowerNfcIdx;
    }

    // Path match (e.g. if queried by path)
    return _resolvePathIndex(word);
  }

  /// Leftmost binary search of [key] in [_searchLowerKeys]; returns the
  /// entry index of the first title (in article order) whose lowercase NFC
  /// key equals [key], or null.
  int? _lowerBoundSearchKey(String key) {
    var lo = 0;
    var hi = _searchLowerKeys.length;
    while (lo < hi) {
      final mid = (lo + hi) >> 1;
      if (_searchLowerKeys[mid].compareTo(key) < 0) {
        lo = mid + 1;
      } else {
        hi = mid;
      }
    }
    if (lo < _searchLowerKeys.length && _searchLowerKeys[lo] == key) {
      return _articleIndices[_searchOrder[lo]];
    }
    return null;
  }

  /// Resolves a path to an entry index against the canonical `ns/path` map.
  ///
  /// [path] is tried as a full `ns/path` key first, then as a bare path with
  /// each namespace present in the archive derived (`ns/path`), in reverse
  /// first-appearance order. That order mirrors the old dual-keyed map's
  /// last-wins result on spec-sorted archives; a bare path that exists under
  /// a single namespace resolves to exactly that entry.
  int? _resolvePathIndex(String path) {
    var idx = _pathToEntryIndex[path];
    if (idx != null) return idx;
    for (var i = _namespaces.length - 1; i >= 0; i--) {
      idx = _pathToEntryIndex['${_namespaces[i]}/$path'];
      if (idx != null) return idx;
    }
    return null;
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

    // Binary search over _searchOrder via the precomputed lowercase keys
    // (each probe used to re-normalize and re-lowercase its title).
    var lo = 0;
    var hi = _searchOrder.length;
    while (lo < hi) {
      final mid = (lo + hi) >> 1;
      if (_searchLowerKeys[mid].compareTo(lowerQuery) < 0) {
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
      if (!_searchLowerKeys[i].startsWith(lowerQuery)) break;
      final title = _articleTitles[_searchOrder[i]];
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

  /// Full-text search over article contents.
  ///
  /// This is a linear scan: it decompresses and reads every article until
  /// [limit] matches are found, so it is far too slow for large archives.
  /// For production full-text search, use the archive's embedded Xapian
  /// index (see [extractFulltextDatabase]) instead of calling this.
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
      final normTitle = normalizeKey(title).toLowerCase();
      if (normTitle.contains(lowerQuery)) {
        final entryIdx = _articleIndices[i];
        if (seen.add(entryIdx)) {
          final entry = await getEntry(entryIdx);
          final text = await entry.readText();
          final snippet = extractSnippet(text, query);
          results.add(ZimSearchResult(
            article: entry,
            snippet: snippet,
            score: normTitle == lowerQuery ? 3.0 : 2.0,
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
        if (normalizeKey(text).toLowerCase().contains(lowerQuery)) {
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
  Future<ZimEntry> getEntry(int index) => _withFileLock(() => _getEntry(index));

  Future<ZimEntry> _getEntry(int index) async {
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
    // The path map holds canonical `ns/path` keys only; bare paths resolve
    // through [_resolvePathIndex], which derives the namespaced candidates.
    var targetIdx = _resolvePathIndex(normalized);

    if (targetIdx == null && currentNamespace != null) {
      targetIdx = _pathToEntryIndex['$currentNamespace/$normalized'];
    }

    if (targetIdx == null) {
      try {
        final decoded = Uri.decodeFull(normalized);
        if (decoded != normalized) {
          targetIdx = _resolvePathIndex(decoded);
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
  Future<Uint8List> readBlob(int clusterNumber, int blobNumber) =>
      _withFileLock(() => _readBlob(clusterNumber, blobNumber));

  Future<Uint8List> _readBlob(int clusterNumber, int blobNumber) async {
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

    // Reuse the streaming path: uncompressed clusters are read straight
    // from disk (only this blob's byte range, never the whole cluster),
    // while compressed clusters go through the decompression cache.
    // Collecting the stream yields exactly the bytes [_extractBlob] used
    // to return for the same blob.
    final stream = await _readBlobStream(clusterNumber, blobNumber);
    final builder = BytesBuilder();
    await for (final chunk in stream) {
      builder.add(chunk);
    }
    return builder.takeBytes();
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
  }) =>
      _withFileLock(
        () => _readBlobStream(
          clusterNumber,
          blobNumber,
          start: start,
          end: end,
        ),
      );

  Future<Stream<List<int>>> _readBlobStream(
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

  /// Imports a `.cidx` index produced by [exportCidx].
  ///
  /// The deserialization and the rebuild of the derived lookup maps run in
  /// a worker isolate when the `.cidx` buffer is at least
  /// [_cidxIsolateThresholdBytes] — at that size the inline parse stalls
  /// the calling isolate for more than a frame, while the isolate path
  /// keeps the stall to the message-copy phases; smaller buffers are
  /// imported inline so a short-lived spawn is not paid for a few
  /// milliseconds of work. Pass [useIsolate] to force either path (a
  /// testing knob; `null` means "decide by size").
  ///
  /// A stale cache throws [FormatException], exactly as before; no reader
  /// state is touched when the import fails, so the caller can fall back
  /// to a full [init].
  @override
  Future<void> importCidx(
    Uint8List bytes, {
    bool? useIsolate,
  }) async {
    final targetFile = File(path);
    // Cheap: one stat call on the calling isolate; the fingerprint values
    // are all the worker needs to validate the cache.
    final stat = targetFile.statSync();
    final runInIsolate =
        useIsolate ?? bytes.length >= _cidxIsolateThresholdBytes;
    final imported = runInIsolate
        ? await Isolate.run(
            () => _importZimCidx(
              bytes,
              stat.size,
              stat.modified.microsecondsSinceEpoch,
            ),
          )
        : _importZimCidx(
            bytes,
            stat.size,
            stat.modified.microsecondsSinceEpoch,
          );

    final d = imported.deserialized;
    _majorVersion = d.majorVersion;
    _minorVersion = d.minorVersion;
    _uuid = d.uuid;
    _entryCount = d.entryCount;
    _clusterCount = d.clusterCount;
    _pathPtrPos = d.pathPtrPos;
    _titlePtrPos = d.titlePtrPos;
    _clusterPtrPos = d.clusterPtrPos;
    _mimeListPos = d.mimeListPos;
    _mainPage = d.mainPage;
    _layoutPage = d.layoutPage;
    _checksumPos = d.checksumPos;
    _mimeTypes = d.mimeTypes;
    _metadata = d.metadata;
    _clusterOffsets = d.clusterOffsets;
    _pathPointers = d.pathPointers;
    _titlePointers = d.titlePointers;
    _articleIndices = d.articleIndices;
    _articleTitles = d.articleTitles;
    _searchOrder = d.searchOrder;
    _pathToEntryIndex = d.pathToEntryIndex;

    _titleToIndex = imported.titleToIndex;
    _normalizedTitles = imported.normalizedTitles;
    _searchLowerKeys = imported.searchLowerKeys;
    _namespaces = imported.namespaces;

    _file = await targetFile.open(mode: FileMode.read);
    _initialized = true;
    _metadataInitialized = true;
  }

  Future<Uint8List> _getDecompressedCluster(int clusterNumber) async {
    final cached = _clusterCache[clusterNumber];
    if (cached != null) {
      _clusterLru.remove(clusterNumber);
      _clusterLru.add(clusterNumber);
      return cached.bytes;
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
    final decompressed = _decompressCluster(clusterData);

    _cacheCluster(clusterNumber, infoByte, decompressed);
    return decompressed;
  }

  /// Inserts a decompressed cluster into the cache, evicting
  /// least-recently-used entries until the total cached bytes fit within
  /// [_maxClusterCacheBytes]. A single cluster larger than the whole
  /// budget is not cached at all, so the cap is never exceeded.
  void _cacheCluster(int clusterNumber, int infoByte, Uint8List bytes) {
    if (bytes.length > _maxClusterCacheBytes) return;
    while (_clusterCacheBytes + bytes.length > _maxClusterCacheBytes &&
        _clusterLru.isNotEmpty) {
      final oldest = _clusterLru.removeAt(0);
      final evicted = _clusterCache.remove(oldest);
      if (evicted != null) _clusterCacheBytes -= evicted.bytes.length;
    }
    _clusterCache[clusterNumber] = _CachedCluster(bytes, infoByte);
    _clusterCacheBytes += bytes.length;
    _clusterLru.add(clusterNumber);
  }

  /// Closes the underlying file and releases memory caches.
  ///
  /// Waits for in-flight reads to finish (via the file lock) so a close can
  /// never strand a concurrent read on a closed handle.
  @override
  Future<void> close() => _withFileLock(() async {
        await _file?.close();
        _file = null;
        _clusterCache.clear();
        _clusterLru.clear();
        _clusterCacheBytes = 0;
        _initialized = false;
        _metadataInitialized = false;
      });
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

class _ImportedZimCidx {
  final DeserializedZimCidx deserialized;
  final Map<String, int> titleToIndex;
  final Map<String, int> normalizedTitles;

  /// Lowercase NFC sort keys parallel to [DeserializedZimCidx.searchOrder].
  final List<String> searchLowerKeys;

  /// Distinct namespaces in first-appearance (serialized) order.
  final List<String> namespaces;

  _ImportedZimCidx({
    required this.deserialized,
    required this.titleToIndex,
    required this.normalizedTitles,
    required this.searchLowerKeys,
    required this.namespaces,
  });
}

/// Deserializes a ZIM `.cidx` buffer and rebuilds the derived lookup maps,
/// as a top-level function so [ZimReader.importCidx] can run it in a worker
/// isolate via [Isolate.run]. Only sendable values cross the boundary:
/// [bytes] plus the two fingerprint integers — the caller stats the file
/// itself, because a [File] cannot be captured by the isolate closure.
/// Throws [FormatException] for a stale cache, like [deserializeZimCidx].
_ImportedZimCidx _importZimCidx(
  Uint8List bytes,
  int fileSize,
  int fileModified,
) {
  final deserialized = deserializeZimCidxWithStat(
    bytes,
    fileSize: fileSize,
    fileModified: fileModified,
  );

  final titleToIndex = <String, int>{};
  final normalizedTitles = <String, int>{};
  final articleTitles = deserialized.articleTitles;
  final articleIndices = deserialized.articleIndices;
  for (var i = 0; i < articleTitles.length; i++) {
    final title = articleTitles[i];
    final entryIdx = articleIndices[i];
    titleToIndex.putIfAbsent(title, () => entryIdx);
    final norm = normalizeKey(title);
    normalizedTitles.putIfAbsent(norm, () => entryIdx);
  }

  // Rebuild the lowercase sort keys from the serialized titles and search
  // order (same precomputation the scanner performs); no extra section is
  // stored in the .cidx, so the format — and its version — is unchanged.
  final searchLowerKeys = [
    for (final articlePos in deserialized.searchOrder)
      normalizeKey(articleTitles[articlePos]).toLowerCase(),
  ];

  // The .cidx stores canonical `ns/path` keys only; recover the distinct
  // namespaces from them (in serialized order) for bare-path lookups.
  final namespaces = <String>{};
  for (final key in deserialized.pathToEntryIndex.keys) {
    final slash = key.indexOf('/');
    if (slash > 0) namespaces.add(key.substring(0, slash));
  }

  return _ImportedZimCidx(
    deserialized: deserialized,
    titleToIndex: titleToIndex,
    normalizedTitles: normalizedTitles,
    searchLowerKeys: searchLowerKeys,
    namespaces: namespaces.toList(),
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

  /// Lowercase NFC sort keys parallel to [searchOrder] (see [_parseZimIndex]).
  final List<String> searchLowerKeys;
  final Map<String, int> titleToIndex;
  final Map<String, int> normalizedTitles;
  final Map<String, int> pathToEntryIndex;

  /// Distinct namespaces in first-appearance (dirent) order.
  final List<String> namespaces;

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
    required this.searchLowerKeys,
    required this.titleToIndex,
    required this.normalizedTitles,
    required this.pathToEntryIndex,
    required this.namespaces,
  });
}

/// Default size of the sliding window [_parseZimIndex] uses to read
/// directory entries: 16 MiB of contiguous bytes per window.
const int _defaultDirentWindowBytes = 16 * 1024 * 1024;

/// `.cidx` buffers at least this large are imported in a worker isolate
/// instead of on the calling isolate ([ZimReader.importCidx]).
///
/// Measured on synthetic `.cidx` buffers (JIT, sandbox, 1.5 shared CPUs;
/// min-of-9 wall times, worst-of-3 event-loop stalls): the inline parse
/// stalls the calling isolate for ~22 ms at 232 KiB, ~150 ms at 2.4 MiB
/// and ~370 ms at 4.9 MiB, while the isolate path keeps the stall to the
/// message-copy phases (single-digit ms up to ~2.4 MiB) at comparable
/// total wall time (within ~30%). 256 KiB sits just above the size where
/// the inline stall first exceeds one 60 fps frame (~16 ms), so small
/// dictionaries skip the isolate spawn and large ones never freeze the
/// calling isolate.
const int _cidxIsolateThresholdBytes = 256 * 1024;

_ParsedZimIndex _parseZimIndex(
  String filePath, {
  int direntWindowBytes = _defaultDirentWindowBytes,
}) {
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
    if (majorVersion < 6) {
      throw FormatException(
        'Unsupported ZIM version $majorVersion.$minorVersion: '
        'only 6.x archives are supported',
      );
    }
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

    // Read and parse all directory entries.
    // Directory entries are usually stored contiguously before pathPtrPos,
    // so they are read through a sliding window of [windowSize] bytes
    // instead of one up-to-100 MiB blob (old behaviour below that span) or
    // one syscall per dirent (old behaviour past it). A dirent straddling
    // the end of a window is retried from a window slid to its own offset;
    // a dirent longer than one window falls back to a bounded direct read.
    final windowSize =
        direntWindowBytes > 0 ? direntWindowBytes : _defaultDirentWindowBytes;
    final fileLen = f.lengthSync();
    var windowStart = -1;
    var windowEnd = -1;
    Uint8List? windowBuffer;

    void loadWindowAt(int start) {
      windowStart = start;
      f.setPositionSync(start);
      windowBuffer = f.readSync(windowSize);
      windowEnd = windowStart + windowBuffer!.length;
    }

    final articleIndices = <int>[];
    final articleTitles = <String>[];

    /// Lowercase NFC sort key per article, parallel to [articleTitles].
    final lowerKeys = <String>[];
    final titleToIndex = <String, int>{};
    final normalizedTitles = <String, int>{};

    /// Canonical `ns/path` -> entry index, one key per dirent.
    final pathToEntryIndex = <String, int>{};
    final namespaceSet = <String>{};
    final metadataEntries = <(String key, int cluster, int blob)>[];

    for (var i = 0; i < entryCount; i++) {
      final offset = pathPointers[i];
      _RawDirent? dirent;

      if (windowBuffer != null && offset >= windowStart && offset < windowEnd) {
        dirent = _tryParseDirent(
          Uint8List.sublistView(windowBuffer!, offset - windowStart),
          i,
        );
      }

      if (dirent == null) {
        // Slide the window to this dirent and retry: covers the first load,
        // a dirent past the previous window, and one straddling its end.
        loadWindowAt(offset);
        if (windowBuffer!.isNotEmpty) {
          dirent = _tryParseDirent(windowBuffer!, i);
        }
      }

      if (dirent == null) {
        // Dirent longer than one window (or unparseable from the window):
        // read it directly, bounded by the next dirent when the pointers
        // are ascending — or by the end of the dirent region for the last
        // entry — so even a multi-megabyte title is read exactly once.
        f.setPositionSync(offset);
        dirent = _tryParseDirent(f.readSync(256), i);
        if (dirent == null) {
          f.setPositionSync(offset);
          dirent = _tryParseDirent(f.readSync(2048), i);
        }
        if (dirent == null) {
          var bound = -1;
          if (i + 1 < entryCount && pathPointers[i + 1] > offset) {
            bound = pathPointers[i + 1] - offset;
          } else if (pathPtrPos > offset) {
            bound = pathPtrPos - offset;
          }
          if (bound > fileLen - offset) bound = fileLen - offset;
          if (bound > 2048) {
            f.setPositionSync(offset);
            dirent = _tryParseDirent(f.readSync(bound), i);
          }
        }
      }

      if (dirent == null) continue;

      final fullPath = '${dirent.namespace}/${dirent.path}';
      // Canonical key only: the bare path is derivable from [_namespaces].
      pathToEntryIndex[fullPath] = i;
      namespaceSet.add(dirent.namespace);

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

      // Article content is text-like: plain text/html, or XHTML (the same
      // definition [ZimEntry.isHtml] uses). The 'C' namespace holds both
      // articles and media in new-namespace archives, so the MIME check is
      // what keeps illustrations out of the word list there.
      final isTextLike =
          mime.startsWith('text/') || mime == 'application/xhtml+xml';
      final isArticle = dirent.namespace == 'A' ||
          (dirent.namespace == 'C' && (isTextLike || dirent.isRedirect)) ||
          (dirent.namespace != 'I' &&
              dirent.namespace != '-' &&
              dirent.namespace != 'W' &&
              dirent.namespace != 'X' &&
              (isTextLike || dirent.isRedirect));

      if (isArticle) {
        articleIndices.add(i);
        articleTitles.add(dirent.title);

        // Precompute the lowercase NFC sort key once per title: the
        // search-order sort and every later binary search reuse it instead
        // of re-normalizing and re-lowercasing on each comparison.
        final nfc = normalizeKey(dirent.title);
        lowerKeys.add(nfc.toLowerCase());

        titleToIndex.putIfAbsent(dirent.title, () => i);
        if (nfc != dirent.title) {
          normalizedTitles.putIfAbsent(nfc, () => i);
        }
      }
    }

    // Search order: indices into articleTitles, sorted by the precomputed
    // lowercase NFC keys. Ties break by article position, so equal keys keep
    // title order (the same winner the old putIfAbsent lowercase map
    // produced for duplicate keys).
    final searchOrder = List<int>.generate(articleTitles.length, (i) => i)
      ..sort((a, b) {
        final cmp = lowerKeys[a].compareTo(lowerKeys[b]);
        return cmp != 0 ? cmp : a.compareTo(b);
      });

    // Lowercase keys in search order, persisted for binary search.
    final searchLowerKeys = [
      for (final articlePos in searchOrder) lowerKeys[articlePos],
    ];

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
      searchLowerKeys: searchLowerKeys,
      titleToIndex: titleToIndex,
      normalizedTitles: normalizedTitles,
      pathToEntryIndex: pathToEntryIndex,
      namespaces: namespaceSet.toList(),
    );
  } finally {
    f.closeSync();
  }
}
