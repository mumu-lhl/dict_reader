import "dart:convert";
import "dart:io";
import "dart:isolate";
import "dart:typed_data";

import "package:blockchain_utils/crypto/crypto/hash/hash.dart";
import "package:charset/charset.dart";
import "package:html_unescape/html_unescape.dart";

const _cacheVersion = 2;
const _utf16Decoder = Utf16Decoder();

Uint8List _fastDecrypt(Uint8List data, Uint8List key) {
  // XOR decryption
  final b = data;
  final keyLength = key.length;
  int previous = 0x36;

  for (int i = 0; i < b.length; i++) {
    int t = (b[i] >> 4 | b[i] << 4) & 0xff;
    t = t ^ previous ^ (i & 0xff) ^ key[i % keyLength];
    previous = b[i];
    b[i] = t;
  }

  return b;
}

int _readByte(List<int> buffer, int byteWidth, [int start = 0]) {
  if (byteWidth == 1) {
    return buffer[start];
  }
  return (buffer[start] << 8) | buffer[start + 1];
}

int _readNumber(List<int> buffer, int numberWidth, [int start = 0]) {
  var value = 0;
  for (var i = 0; i < numberWidth; i++) {
    value = (value << 8) | buffer[start + i];
  }
  return value;
}

List<int> _sliceBytes(List<int> data, int start, int end) {
  if (data is Uint8List) {
    return Uint8List.sublistView(data, start, end);
  }
  return data.sublist(start, end);
}

int _findByteTerminator(Uint8List bytes, int start) {
  var index = start;
  while (index < bytes.length && bytes[index] != 0) {
    index++;
  }
  return index;
}

int _findUtf16Terminator(Uint8List bytes, int start) {
  var index = start;
  while (index + 1 < bytes.length &&
      (bytes[index] != 0 || bytes[index + 1] != 0)) {
    index += 2;
  }
  return index;
}

/// Reading MDX/MDD files.
class DictReader {
  final String _path;
  final Map<String, (String, String)> _stylesheet = {};

  late int numEntries;
  late int _numberWidth;
  late int _keyBlockOffset;
  late int _recordBlockOffset;
  late bool _mdx;
  late double _version;
  late String _encoding;
  late String _normalizedEncoding;
  Encoding? _textCodec;
  bool _headerLoaded = false;
  File? _dict;
  late List<(int, String)> _keyList;
  late List<int> _lookupKeyIndices;
  late int _encrypt;
  RandomAccessFile? _f;
  List<(int, int)>? _recordBlockInfoList;
  int? _totalDecompressedSize;
  List<int>? _recordBlockDecompressedStarts;
  List<int>? _recordBlockFileOffsets;
  final Map<(int, int), List<int>> _recordBlockCache = {};
  int _recordBlockCacheSize = 0;

  static const _maxRecordBlockCacheSize = 32 * 1024 * 1024;

  late Map<String, String> header;

  void Function()? _onHeaderRead;
  void Function()? _onRecordBlockInfoRead;

  /// [_path] File path
  DictReader(this._path) {
    _mdx = _path.toLowerCase().endsWith(".mdx");
  }

  /// Initialize
  ///
  /// Will not read key if [readKey] is false to reduce initialization time.
  @Deprecated("Use initDict instead.")
  Future<void> init([bool readKey = true]) async {
    await close();
    _dict = File(_path);
    _f = await _dict!.open();
    header = await _readHeader();
    _headerLoaded = true;
    if (readKey) {
      _keyList = await _readKeys();
      _rebuildLookupKeyList();
      await _readRecordBlockInfo();
    }
  }

  /// Initializes the dictionary.
  ///
  /// [readKeys] determines whether to read the key list.
  /// [readRecordBlockInfo] determines whether to read the record block information.
  /// [readHeader] determines whether to read the dictionary header.
  Future<void> initDict(
      {bool readKeys = true,
      bool readRecordBlockInfo = true,
      bool readHeader = true}) async {
    if (_f == null) {
      _dict = File(_path);
      _f = await _dict!.open();
    }

    if (readHeader || (!_headerLoaded && (readKeys || readRecordBlockInfo))) {
      header = await _readHeader(notify: readHeader);
      _headerLoaded = true;
    }

    if (readKeys || readRecordBlockInfo) {
      final path = _path;
      final keyBlockOffset = _keyBlockOffset;
      final version = _version;
      final numberWidth = _numberWidth;
      final encrypt = _encrypt;
      final encoding = _encoding;
      final initData = await Isolate.run(() => _initDictIsolate(
          path,
          readKeys,
          readRecordBlockInfo,
          keyBlockOffset,
          version,
          numberWidth,
          encrypt,
          encoding));

      if (readKeys) {
        _keyList = initData.keyList!;
        _rebuildLookupKeyList();
      }
      numEntries = initData.numEntries!;
      _recordBlockOffset = initData.recordBlockOffset!;

      if (readRecordBlockInfo) {
        _recordBlockInfoList = initData.recordBlockInfoList;
        _totalDecompressedSize = initData.totalDecompressedSize;
        _buildRecordBlockIndex();

        if (_onRecordBlockInfoRead != null) {
          _onRecordBlockInfoRead!();
        }
      }
    }
  }

  /// Closes the dictionary file.
  Future<void> close() async {
    final file = _f;
    _f = null;
    await file?.close();
    _dict = null;
    _headerLoaded = false;
    _recordBlockInfoList = null;
    _totalDecompressedSize = null;
    _recordBlockDecompressedStarts = null;
    _recordBlockFileOffsets = null;
    _recordBlockCache.clear();
    _recordBlockCacheSize = 0;
  }

  /// Exports the cache data as a map.
  ///
  /// This method extracts the key list, number of entries, record block offset,
  /// record block info list, and total decompressed size into a map, which can
  /// be used for caching. This operation is performed in an isolate.
  Future<Map<String, dynamic>> exportCache() async {
    final file = File(_path);
    final stat = await file.stat();
    final filePath = await file.resolveSymbolicLinks();
    final keyList = _keyList;
    final numEntries = this.numEntries;
    final recordBlockOffset = _recordBlockOffset;
    final recordBlockInfoList = _recordBlockInfoList;
    final totalDecompressedSize = _totalDecompressedSize;
    return Isolate.run(() => _exportCacheIsolate(
          keyList,
          numEntries,
          recordBlockOffset,
          recordBlockInfoList,
          totalDecompressedSize,
          filePath,
          stat.size,
          stat.modified.microsecondsSinceEpoch,
        ));
  }

  /// Exports the cache data as a JSON string.
  ///
  /// This is a convenience method that calls [exportCache] and returns the
  /// result as a JSON-encoded string. This operation is performed in an isolate.
  Future<String> exportCacheAsString() async {
    final cacheMap = await exportCache();
    return Isolate.run(() => jsonEncode(cacheMap));
  }

  /// Imports cache data from a map.
  ///
  /// This method populates the dictionary's fields from a cache map, avoiding
  /// the need to re-read and process the dictionary file. This operation is
  /// performed in an isolate.
  Future<void> _validateCache(Map<String, dynamic> cacheData) async {
    if (cacheData['cacheVersion'] != _cacheVersion) {
      throw const FormatException("Unsupported dictionary cache version");
    }

    final cachedPath = cacheData['filePath'];
    if (cachedPath is! String) {
      throw const FormatException("Dictionary cache has no file identity");
    }

    final file = File(_path);
    final actualPath = await file.resolveSymbolicLinks();
    if (cachedPath != actualPath) {
      throw const FormatException("Dictionary cache belongs to another file");
    }

    final stat = await file.stat();
    if (cacheData['fileSize'] != stat.size ||
        cacheData['fileModified'] != stat.modified.microsecondsSinceEpoch) {
      throw const FormatException(
          "Dictionary file has changed since cache export");
    }
  }

  Future<void> importCache(Map<String, dynamic> cacheData) async {
    await _validateCache(cacheData);
    if (_f == null) {
      _dict = File(_path);
      _f = await _dict!.open();
    }
    if (!_headerLoaded) {
      header = await _readHeader();
      _headerLoaded = true;
    }

    final importedData =
        await Isolate.run(() => _importCacheIsolate(cacheData));
    _keyList = importedData['keyList'] as List<(int, String)>;
    _rebuildLookupKeyList();
    numEntries = importedData['numEntries'];
    _recordBlockOffset = importedData['recordBlockOffset'];
    _recordBlockInfoList =
        importedData['recordBlockInfoList'] as List<(int, int)>?;
    _totalDecompressedSize = importedData['totalDecompressedSize'];
    _buildRecordBlockIndex();
  }

  /// Imports cache data from a JSON string.
  ///
  /// This is a convenience method that decodes a JSON string and calls
  /// [importCache] with the resulting map.
  Future<void> importCacheFromString(String cacheString) async {
    final cacheData = await Isolate.run(() => jsonDecode(cacheString));
    await importCache(cacheData);
  }

  /// Sets a callback function to be called after the header is read.
  void setOnHeaderRead(void Function() callback) {
    _onHeaderRead = callback;
  }

  /// Sets a callback function to be called after the record block info is read.
  void setOnRecordBlockInfoRead(void Function() callback) {
    _onRecordBlockInfoRead = callback;
  }

  /// Reads records
  ///
  /// If [returnData] is false.
  /// Returns `Stream<(String, (int, int, int, int))>`.
  /// `(int, int, int, int)` can be passed to [readOneMdx] or [readOneMdd] in turn.
  ///
  /// If [returnData] is true.
  /// Returns `Stream<(String, String)` when file format is mdx.
  /// Returns `Stream<(String, List<int>)` when file format is mdd.
  ///
  /// The first member of the returned record is the key text.
  @Deprecated("Use readWithMdxData and readWithMddData instead.")
  Stream<(String, dynamic)> read([bool returnData = false]) async* {
    if (returnData) {
      if (_mdx) {
        await for (final record in readWithMdxData()) {
          yield (record.keyText, record.data);
        }
      } else {
        await for (final record in readWithMddData()) {
          yield (record.keyText, record.data);
        }
      }
      return;
    }

    await for (final offsetInfo in readWithOffset()) {
      if (offsetInfo.segments.length > 1) {
        throw UnsupportedError(
            "Use readWithOffset for records spanning multiple blocks");
      }
      yield (
        offsetInfo.keyText,
        (
          offsetInfo.recordBlockOffset,
          offsetInfo.startOffset,
          offsetInfo.endOffset,
          offsetInfo.compressedSize,
        )
      );
    }
  }

  /// Only reads one record.
  ///
  /// [offset], [startOffset], [endOffset], [compressedSize] are obtained from [read].
  /// Returns `String` if file format is mdx.
  /// Returns `List<int>` if file format is mdd.
  @Deprecated("Use readOneMdx or readOneMdd instead.")
  dynamic readOne(
      int offset, int startOffset, int endOffset, int compressedSize) async {
    final recordBlock = await _readRecordBlockAt(offset, compressedSize);
    final originalData = recordBlock.sublist(startOffset, endOffset);
    final data = _mdx ? _treatRecordMdxData(originalData) : originalData;

    return data;
  }

  Future<RandomAccessFile> _openReadHandle() async {
    if (_f == null) {
      throw StateError("Dictionary is not initialized");
    }
    return File(_path).open();
  }

  List<int>? _takeCachedRecordBlock(int offset, int compressedSize) {
    final cacheKey = (offset, compressedSize);
    final cached = _recordBlockCache.remove(cacheKey);
    if (cached != null) {
      // Map preserves insertion order, so removing and re-inserting gives us
      // a small LRU cache without another dependency.
      _recordBlockCache[cacheKey] = cached;
    }
    return cached;
  }

  void _cacheRecordBlock(int offset, int compressedSize, List<int> block) {
    final cacheKey = (offset, compressedSize);
    final previous = _recordBlockCache.remove(cacheKey);
    if (previous != null) {
      _recordBlockCacheSize -= previous.length;
    }
    if (block.length > _maxRecordBlockCacheSize) {
      return;
    }

    _recordBlockCache[cacheKey] = block;
    _recordBlockCacheSize += block.length;
    while (_recordBlockCacheSize > _maxRecordBlockCacheSize &&
        _recordBlockCache.isNotEmpty) {
      final oldestKey = _recordBlockCache.keys.first;
      final oldest = _recordBlockCache.remove(oldestKey)!;
      _recordBlockCacheSize -= oldest.length;
    }
  }

  Future<List<int>> _readRecordBlockFromHandle(
      RandomAccessFile f, int offset, int compressedSize) async {
    await f.setPosition(offset);
    final block = _decodeBlock(await f.read(compressedSize));
    _cacheRecordBlock(offset, compressedSize, block);
    return block;
  }

  Future<List<int>> _readRecordBlockAt(int offset, int compressedSize) async {
    if (_f == null) {
      throw StateError("Dictionary is not initialized");
    }
    final cached = _takeCachedRecordBlock(offset, compressedSize);
    if (cached != null) {
      return cached;
    }

    final f = await _openReadHandle();
    try {
      return await _readRecordBlockFromHandle(f, offset, compressedSize);
    } finally {
      await f.close();
    }
  }

  Future<List<int>> _readRecordData(RecordOffsetInfo recordOffsetInfo) async {
    if (_f == null) {
      throw StateError("Dictionary is not initialized");
    }
    RandomAccessFile? f;
    try {
      final segments = recordOffsetInfo.segments.isEmpty
          ? <(int, int, int, int)>[
              (
                recordOffsetInfo.recordBlockOffset,
                recordOffsetInfo.startOffset,
                recordOffsetInfo.endOffset,
                recordOffsetInfo.compressedSize,
              )
            ]
          : recordOffsetInfo.segments;
      var dataLength = 0;
      for (final segment in segments) {
        if (segment.$2 < 0 || segment.$3 < segment.$2) {
          throw FormatException("Invalid record offset");
        }
        dataLength += segment.$3 - segment.$2;
      }
      final data = Uint8List(dataLength);
      var dataOffset = 0;

      for (final segment in segments) {
        var recordBlock = _takeCachedRecordBlock(segment.$1, segment.$4);
        if (recordBlock == null) {
          f ??= await _openReadHandle();
          recordBlock =
              await _readRecordBlockFromHandle(f, segment.$1, segment.$4);
        }
        if (segment.$3 > recordBlock.length) {
          throw FormatException("Record offset exceeds record block");
        }
        final segmentLength = segment.$3 - segment.$2;
        data.setRange(
            dataOffset, dataOffset + segmentLength, recordBlock, segment.$2);
        dataOffset += segmentLength;
      }

      return data;
    } finally {
      await f?.close();
    }
  }

  /// Only reads a mdd file's one record.
  ///
  /// [recordOffsetInfo] is obtained from [readWithOffset].
  /// Returns `List<int>`.
  Future<List<int>> readOneMdd(RecordOffsetInfo recordOffsetInfo) {
    return _readRecordData(recordOffsetInfo);
  }

  /// Only reads a mdx file's one record.
  ///
  /// [recordOffsetInfo] is obtained from [readWithOffset].
  /// Returns `String` if file format is mdx.
  /// Returns `List<int>` if file format is mdd.
  Future<String> readOneMdx(RecordOffsetInfo recordOffsetInfo) async {
    final data = await _readRecordData(recordOffsetInfo);
    return _treatRecordMdxData(data);
  }

  /// Reads records from an MDD file and returns a stream of [MddRecord] objects.
  ///
  /// Each [MddRecord] contains the key text and the raw MDD data (`List<int>`).
  Stream<MddRecord> readWithMddData() async* {
    yield* _readRecords((keyText, originalData, segments) {
      return MddRecord(keyText, originalData);
    });
  }

  /// Reads records from an MDX file and returns a stream of [MdxRecord] objects.
  ///
  /// Each [MdxRecord] contains the key text and the processed MDX data.
  Stream<MdxRecord> readWithMdxData() async* {
    yield* _readRecords((keyText, originalData, segments) {
      final data = _treatRecordMdxData(originalData);
      return MdxRecord(keyText, data);
    });
  }

  /// Reads records and returns a stream of [RecordOffsetInfo] object.
  ///
  /// The `RecordOffsetInfo` contains the `recordBlockOffset`, `startOffset`,
  /// `endOffset`, and `compressedSize` which can be used to read the record data
  /// later using [readOneMdx] or [readOneMdd].
  Stream<RecordOffsetInfo> readWithOffset() async* {
    yield* _readRecords((keyText, originalData, segments) {
      final firstSegment = segments.first;
      return RecordOffsetInfo(
        keyText,
        firstSegment.$1,
        firstSegment.$2,
        firstSegment.$3,
        firstSegment.$4,
        segments: segments,
      );
    }, readData: false);
  }

  /// Locates the position information of a key (word).
  ///
  /// This method can be used to get the content of a key after initialization.
  /// Returns `null` if the key is not found.
  Future<RecordOffsetInfo?> locate(String key) async {
    final keyIndex = _lookupBinarySearch(key);

    if (keyIndex < 0) {
      return null;
    }

    final physicalIndex = _lookupKeyIndices[keyIndex];
    final recordStart = _keyList[physicalIndex].$1;
    final recordEnd = (physicalIndex < _keyList.length - 1)
        ? _keyList[physicalIndex + 1].$1
        : -1; // -1 indicates the last record
    return _buildRecordOffsetInfo(key, recordStart, recordEnd);
  }

  /// Locates the position information of all occurrences of a key (word).
  ///
  /// This method can be used to get the content of a key after initialization.
  /// Returns an empty list if the key is not found.
  Future<List<RecordOffsetInfo>> locateAll(String key) async {
    final results = <RecordOffsetInfo>[];
    // Use lowerBound to find the first potential match.
    var keyIndex = _lookupLowerBound(key);

    if (keyIndex == _lookupKeyIndices.length ||
        _keyList[_lookupKeyIndices[keyIndex]].$2 != key) {
      return [];
    }

    while (keyIndex < _lookupKeyIndices.length &&
        _keyList[_lookupKeyIndices[keyIndex]].$2 == key) {
      final physicalIndex = _lookupKeyIndices[keyIndex];
      final recordStart = _keyList[physicalIndex].$1;
      final recordEnd = (physicalIndex < _keyList.length - 1)
          ? _keyList[physicalIndex + 1].$1
          : -1; // -1 indicates the last record
      final offsetInfo = _buildRecordOffsetInfo(key, recordStart, recordEnd);
      if (offsetInfo != null) {
        results.add(offsetInfo);
      }
      keyIndex++;
    }

    return results;
  }

  /// Searches for keys containing the given text.
  ///
  /// This method can be used to get the content of a key after initialization.
  /// Returns an empty list if the key is not found.
  List<String> search(String key, {int? limit}) {
    // Use lowerBound to find the first potential match.
    final firstMatchIndex = _lookupLowerBound(key);

    return _collectMatches(_lookupKeyIndices, key, firstMatchIndex, limit);
  }

  /// Checks if a key (word) exists in the dictionary.
  ///
  /// Returns `true` if the key is found, otherwise `false`.
  bool exist(String key) {
    return _lookupBinarySearch(key) >= 0;
  }

  int _lookupBinarySearch(String key) {
    var min = 0;
    var max = _lookupKeyIndices.length;
    while (min < max) {
      final middle = min + ((max - min) >> 1);
      final comparison = _keyList[_lookupKeyIndices[middle]].$2.compareTo(key);
      if (comparison == 0) {
        return middle;
      }
      if (comparison < 0) {
        min = middle + 1;
      } else {
        max = middle;
      }
    }
    return -1;
  }

  int _lookupLowerBound(String key) {
    var min = 0;
    var max = _lookupKeyIndices.length;
    while (min < max) {
      final middle = min + ((max - min) >> 1);
      final comparison = _keyList[_lookupKeyIndices[middle]].$2.compareTo(key);
      if (comparison < 0) {
        min = middle + 1;
      } else {
        max = middle;
      }
    }
    return min;
  }

  void _rebuildLookupKeyList() {
    final lookupKeyIndices =
        List<int>.generate(_keyList.length, (index) => index);
    lookupKeyIndices.sort((a, b) {
      final keyComparison = _keyList[a].$2.compareTo(_keyList[b].$2);
      return keyComparison != 0 ? keyComparison : a.compareTo(b);
    });
    _lookupKeyIndices = lookupKeyIndices;
  }

  void _buildRecordBlockIndex() {
    final blockInfoList = _recordBlockInfoList;
    if (blockInfoList == null) {
      _recordBlockDecompressedStarts = null;
      _recordBlockFileOffsets = null;
      return;
    }

    final decompressedStarts = List<int>.filled(blockInfoList.length, 0);
    final fileOffsets = List<int>.filled(blockInfoList.length, 0);
    var decompressedOffset = 0;
    var fileOffset = _recordBlockOffset + _numberWidth * 4;
    fileOffset += blockInfoList.length * _numberWidth * 2;

    for (var i = 0; i < blockInfoList.length; i++) {
      decompressedStarts[i] = decompressedOffset;
      fileOffsets[i] = fileOffset;
      decompressedOffset += blockInfoList[i].$2;
      fileOffset += blockInfoList[i].$1;
    }

    _recordBlockDecompressedStarts = decompressedStarts;
    _recordBlockFileOffsets = fileOffsets;
  }

  RecordOffsetInfo? _buildRecordOffsetInfo(
      String key, int recordStart, int recordEnd) {
    final blockInfoList = _recordBlockInfoList;
    if (blockInfoList == null) {
      return null;
    }

    final actualRecordEnd =
        recordEnd == -1 ? _totalDecompressedSize! : recordEnd;
    if (recordStart < 0 || actualRecordEnd < recordStart) {
      return null;
    }

    if (_recordBlockDecompressedStarts == null ||
        _recordBlockFileOffsets == null) {
      _buildRecordBlockIndex();
    }
    final decompressedStarts = _recordBlockDecompressedStarts!;
    final fileOffsets = _recordBlockFileOffsets!;

    // Find the first block whose end is after recordStart. This changes the
    // common locate path from a full metadata scan to a binary search.
    var low = 0;
    var high = blockInfoList.length;
    while (low < high) {
      final middle = (low + high) >> 1;
      final blockEnd = decompressedStarts[middle] + blockInfoList[middle].$2;
      if (blockEnd <= recordStart) {
        low = middle + 1;
      } else {
        high = middle;
      }
    }

    final segments = <(int, int, int, int)>[];
    for (var blockIndex = low;
        blockIndex < blockInfoList.length;
        blockIndex++) {
      final compressedSize = blockInfoList[blockIndex].$1;
      final decompressedSize = blockInfoList[blockIndex].$2;
      final blockStart = decompressedStarts[blockIndex];
      final blockEnd = blockStart + decompressedSize;

      if (recordStart < blockEnd && actualRecordEnd > blockStart) {
        final startOffset =
            recordStart > blockStart ? recordStart - blockStart : 0;
        final endOffset = actualRecordEnd < blockEnd
            ? actualRecordEnd - blockStart
            : decompressedSize;
        if (endOffset >= startOffset) {
          segments.add((
            fileOffsets[blockIndex],
            startOffset,
            endOffset,
            compressedSize
          ));
        }
      }
      if (actualRecordEnd <= blockEnd) {
        break;
      }
    }

    if (segments.isEmpty) {
      return null;
    }

    final firstSegment = segments.first;
    return RecordOffsetInfo(
      key,
      firstSegment.$1,
      firstSegment.$2,
      firstSegment.$3,
      firstSegment.$4,
      segments: segments,
    );
  }

  /// Collects all matching keys starting from a given index.
  List<String> _collectMatches(
      List<int> list, String key, int startIndex, int? limit) {
    final matchedKeys = <String>[];
    for (var i = startIndex; i < list.length; i++) {
      if (limit != null && matchedKeys.length >= limit) {
        break;
      }
      final currentKey = _keyList[list[i]].$2;
      if (currentKey.startsWith(key)) {
        matchedKeys.add(currentKey);
      } else {
        // Since the list is sorted, we can stop as soon as we find a non-match.
        break;
      }
    }
    return matchedKeys;
  }

  void _configureEncoding() {
    _normalizedEncoding = _encoding.toUpperCase();
    if (_normalizedEncoding == "UTF-16" ||
        _normalizedEncoding == "UTF-16LE" ||
        _normalizedEncoding == "UTF-16BE" ||
        _normalizedEncoding == "UTF-8" ||
        _normalizedEncoding == "UTF8") {
      _textCodec = null;
    } else {
      _textCodec = Charset.getByName(_encoding);
    }
  }

  bool get _isUtf16 {
    final encoding = _normalizedEncoding;
    return encoding == "UTF-16" ||
        encoding == "UTF-16LE" ||
        encoding == "UTF-16BE";
  }

  String _decodeUtf8IgnoringMalformed(List<int> data) {
    // Let the VM's decoder handle the overwhelmingly common valid case. The
    // custom path below is retained because this package intentionally skips
    // malformed bytes instead of emitting U+FFFD.
    try {
      return utf8.decode(data);
    } on FormatException {
      // Fall through to the compatibility decoder.
    }

    final codePoints = <int>[];
    var i = 0;

    bool isContinuation(int index) {
      return index < data.length && (data[index] & 0xc0) == 0x80;
    }

    while (i < data.length) {
      final first = data[i];
      if (first <= 0x7f) {
        codePoints.add(first);
        i++;
        continue;
      }

      var length = 0;
      var codePoint = 0;
      if (first >= 0xc2 && first <= 0xdf && isContinuation(i + 1)) {
        length = 2;
        codePoint = first & 0x1f;
      } else if (first >= 0xe0 &&
          first <= 0xef &&
          isContinuation(i + 1) &&
          isContinuation(i + 2) &&
          !(first == 0xe0 && data[i + 1] < 0xa0) &&
          !(first == 0xed && data[i + 1] >= 0xa0)) {
        length = 3;
        codePoint = first & 0x0f;
      } else if (first >= 0xf0 &&
          first <= 0xf4 &&
          isContinuation(i + 1) &&
          isContinuation(i + 2) &&
          isContinuation(i + 3) &&
          !(first == 0xf0 && data[i + 1] < 0x90) &&
          !(first == 0xf4 && data[i + 1] > 0x8f)) {
        length = 4;
        codePoint = first & 0x07;
      }

      if (length == 0) {
        i++;
        continue;
      }

      for (var j = 1; j < length; j++) {
        codePoint = (codePoint << 6) | (data[i + j] & 0x3f);
      }
      codePoints.add(codePoint);
      i += length;
    }

    return String.fromCharCodes(codePoints);
  }

  String _decodeText(List<int> data) {
    final encoding = _normalizedEncoding;
    if (encoding == "UTF-16BE") {
      return _utf16Decoder.decodeUtf16Be(data);
    }
    if (encoding == "UTF-16" || encoding == "UTF-16LE") {
      return _utf16Decoder.decodeUtf16Le(data);
    }
    if (encoding == "UTF-8" || encoding == "UTF8") {
      return _decodeUtf8IgnoringMalformed(data);
    }

    final codec = _textCodec;
    if (codec == null) {
      throw FormatException("Unsupported dictionary encoding: $_encoding");
    }
    if (codec is GbkCodec) {
      return codec.decode(data, allowMalformed: true);
    }
    if (codec is CodePage) {
      return codec.decode(data, allowInvalid: true);
    }
    return codec.decode(data);
  }

  String _stripNul(String value) {
    var start = 0;
    var end = value.length;
    while (start < end && value.codeUnitAt(start) == 0) {
      start++;
    }
    while (end > start && value.codeUnitAt(end - 1) == 0) {
      end--;
    }
    return value.substring(start, end);
  }

  List<int> _decodeBlock(List<int> block) {
    // The compression method is stored in the low nibble of the first
    // little-endian word, so reading the first byte is sufficient.
    final compressionMethod = block[0] & 0xf;
    final data = _sliceBytes(block, 8, block.length);

    if (compressionMethod == 0) {
      return data;
    }
    if (compressionMethod == 2) {
      return zlib.decode(data);
    }
    throw "Compression method not supported";
  }

  List<(int, String)> _decodeKeyBlock(
      List<int> keyBlockCompressed, List<int> keyBlockInfoList) {
    final List<(int, String)> keyList = [];
    var i = 0;

    for (final compressedSize in keyBlockInfoList) {
      final keyBlock =
          _decodeBlock(_sliceBytes(keyBlockCompressed, i, i + compressedSize));
      keyList.addAll(_splitKeyBlock(keyBlock));
      i += compressedSize;
    }

    return keyList;
  }

  List<int> _decodeKeyBlockInfo(List<int> keyBlockInfoCompressed) {
    List<int> keyBlockInfo;

    if (_version >= 2.0) {
      if ((_encrypt & 0x02) != 0) {
        final key = RIPEMD128
            .hash(keyBlockInfoCompressed.sublist(4, 8) + [149, 54, 0, 0]);
        final encrypted = keyBlockInfoCompressed is Uint8List
            ? Uint8List.sublistView(keyBlockInfoCompressed, 8)
            : Uint8List.fromList(keyBlockInfoCompressed.sublist(8));
        _fastDecrypt(encrypted, Uint8List.fromList(key));
        keyBlockInfo = zlib.decode(encrypted);
      } else {
        keyBlockInfo = zlib.decode(_sliceBytes(
            keyBlockInfoCompressed, 8, keyBlockInfoCompressed.length));
      }
    } else {
      keyBlockInfo = keyBlockInfoCompressed;
    }

    final List<int> keyBlockInfoList = [];

    var byteWidth = 1;
    var textTerm = 0;

    if (_version >= 2.0) {
      byteWidth = 2;
      textTerm = 1;
    }

    for (var i = 0; i < keyBlockInfo.length;) {
      i += _numberWidth;

      // text head size
      final textHeadSize = _readByte(keyBlockInfo, byteWidth, i);
      i += byteWidth;

      // text head
      if (!_isUtf16) {
        i += textHeadSize + textTerm;
      } else {
        i += (textHeadSize + textTerm) * 2;
      }

      // text tail size
      final textTailSize = _readByte(keyBlockInfo, byteWidth, i);
      i += byteWidth;

      // text tail
      if (!_isUtf16) {
        i += textTailSize + textTerm;
      } else {
        i += (textTailSize + textTerm) * 2;
      }

      // key block compressed size
      final keyBlockCompressedSize = _readNumber(keyBlockInfo, _numberWidth, i);
      i += _numberWidth;
      // key block decompressed size
      _readNumber(keyBlockInfo, _numberWidth, i);
      i += _numberWidth;

      keyBlockInfoList.add(keyBlockCompressedSize);
    }

    return keyBlockInfoList;
  }

  Map<String, String> _parseHeader(String header) {
    final RegExp regex = RegExp(r'(\w+)="(.*?)"', dotAll: true);
    final Map<String, String> tagDict = {};

    final Iterable<RegExpMatch> matches = regex.allMatches(header);
    for (final match in matches) {
      final String key = match.group(1)!;
      final String value = match.group(2)!;
      tagDict[key] = value;
    }

    return tagDict;
  }

  Future<Map<String, String>> _readHeader({bool notify = true}) async {
    final f = _f!;
    await f.setPosition(0);
    var headerBytesSize = await _readNumberer(f, 4);

    var contentBytes = await f.read(headerBytesSize);
    String content;
    _keyBlockOffset = headerBytesSize + 8;

    if (contentBytes[contentBytes.length - 1] == 0 &&
        contentBytes[contentBytes.length - 2] == 0) {
      content = Utf16Decoder()
          .decodeUtf16Le(contentBytes.sublist(0, contentBytes.length - 2));
    } else {
      content = Utf8Decoder()
          .convert(contentBytes.sublist(0, contentBytes.length - 1));
    }

    final tags = _parseHeader(content);

    String? encoding = tags["Encoding"];
    if (encoding == null || encoding == "") {
      if (_mdx) {
        encoding = "UTF-8";
      } else {
        encoding = "UTF-16";
      }
    }
    // GB18030 > GBK > GB2312
    if (["GBK", "GB2312"].contains(encoding.toUpperCase())) {
      encoding = "GB18030";
    }
    _encoding = encoding;

    // encryption flag
    //   0x00 - no encryption, "Allow export to text" is checked in MdxBuilder 3.
    //   0x01 - encrypt record block, "Encryption Key" is given in MdxBuilder 3.
    //   0x02 - encrypt key info block, "Allow export to text" is unchecked in MdxBuilder 3.
    if (!tags.containsKey("Encrypted") || tags["Encrypted"] == "No") {
      _encrypt = 0;
    } else if (tags["Encrypted"] == "Yes") {
      _encrypt = 1;
    } else {
      _encrypt = int.parse(tags["Encrypted"]!);
    }

    // stylesheet attribute if present takes form of:
    //   style_number # 1-255
    //   style_begin  # or ''
    //   style_end    # or ''
    // store stylesheet in dict in the form of
    // {'number' : ('style_begin', 'style_end')}
    _stylesheet.clear();
    final stylesheetString = tags["StyleSheet"];
    if (stylesheetString != null) {
      final unescape = HtmlUnescape();
      final lines = LineSplitter().convert(stylesheetString);
      for (int i = 0; i < lines.length; i += 3) {
        _stylesheet[lines[i]] =
            (unescape.convert(lines[i + 1]), unescape.convert(lines[i + 2]));
      }
    }

    // before version 2.0, number is 4 bytes integer
    // version 2.0 and above uses 8 bytes
    _version = double.parse(tags["GeneratedByEngineVersion"]!);
    if (_version < 2.0) {
      _numberWidth = 4;
    } else {
      _numberWidth = 8;

      // version 3.0 uses UTF-8 only
      if (_version >= 3.0) {
        _encoding = "UTF-8";
      }
    }
    _configureEncoding();

    if (notify && _onHeaderRead != null) {
      _onHeaderRead!();
    }

    return tags;
  }

  Future<(int, int, int)> _readKeySectionHeader(RandomAccessFile f) async {
    // v1 has four 4/8-byte fields; v2 adds the decompressed-info size and a
    // four-byte checksum. Read the fixed header in one operation instead of
    // issuing a separate asynchronous read for every field.
    final headerSize =
        _numberWidth * (_version >= 2.0 ? 5 : 4) + (_version >= 2.0 ? 4 : 0);
    final bytes = await f.read(headerSize);
    var offset = 0;

    // number of key blocks
    _readNumber(bytes, _numberWidth, offset);
    offset += _numberWidth;

    numEntries = _readNumber(bytes, _numberWidth, offset);
    offset += _numberWidth;

    // number of bytes of key block info after decompression
    if (_version >= 2.0) {
      offset += _numberWidth;
    }

    final keyBlockInfoSize = _readNumber(bytes, _numberWidth, offset);
    offset += _numberWidth;
    final keyBlockSize = _readNumber(bytes, _numberWidth, offset);

    return (numEntries, keyBlockInfoSize, keyBlockSize);
  }

  Future<List<(int, String)>> _readKeys() async {
    final f = _f!;
    await f.setPosition(_keyBlockOffset);

    final (_, keyBlockInfoSize, keyBlockSize) = await _readKeySectionHeader(f);
    final bytes = await f.read(keyBlockInfoSize);
    final keyBlockInfoList = _decodeKeyBlockInfo(bytes);

    // Read the compressed key blocks once. _decodeKeyBlock uses typed views
    // where possible, so this no longer makes an extra full-size copy.
    final keyBlockCompressed = await f.read(keyBlockSize);
    final keyList = _decodeKeyBlock(keyBlockCompressed, keyBlockInfoList);

    _recordBlockOffset = await f.position();

    return keyList;
  }

  Future<int> _readNumberer(RandomAccessFile file, [int? numberWidth]) async {
    numberWidth ??= _numberWidth;
    final bytes = await file.read(numberWidth);

    return _readNumber(bytes, numberWidth);
  }

  Future<void> _skipKeys() async {
    final f = _f!;
    await f.setPosition(_keyBlockOffset);

    final (_, keyBlockInfoSize, keyBlockSize) = await _readKeySectionHeader(f);
    final keyBlockOffset = await f.position();
    _recordBlockOffset = keyBlockOffset + keyBlockInfoSize + keyBlockSize;
    await f.setPosition(_recordBlockOffset);
  }

  Future<List<(int, int)>> _readRecordBlockInfoFromHandle(
      RandomAccessFile f) async {
    // The four record-section header fields and all block metadata are fixed
    // width. Reading them in two chunks avoids 2 * blockCount tiny async IO
    // operations for dictionaries with many record blocks.
    final header = await f.read(_numberWidth * 4);
    final numRecordBlocks = _readNumber(header, _numberWidth);
    final infoBytes = await f.read(numRecordBlocks * _numberWidth * 2);
    final recordBlockInfoList = <(int, int)>[];
    var offset = 0;
    for (var i = 0; i < numRecordBlocks; i++) {
      final compressedSize = _readNumber(infoBytes, _numberWidth, offset);
      offset += _numberWidth;
      final decompressedSize = _readNumber(infoBytes, _numberWidth, offset);
      offset += _numberWidth;
      recordBlockInfoList.add((compressedSize, decompressedSize));
    }
    return recordBlockInfoList;
  }

  Future<void> _readRecordBlockInfo() async {
    final f = _f!;
    await f.setPosition(_recordBlockOffset);

    _recordBlockInfoList = await _readRecordBlockInfoFromHandle(f);
    _totalDecompressedSize = _recordBlockInfoList!
        .fold<int>(0, (total, blockInfo) => total + blockInfo.$2);
    _buildRecordBlockIndex();
  }

  Stream<T> _readRecords<T>(
      T Function(String keyText, List<int> originalData,
              List<(int, int, int, int)> segments)
          recordProcessor,
      {bool readData = true}) async* {
    final f = await _openReadHandle();
    try {
      yield* _readRecordsFromHandle(f, recordProcessor, readData: readData);
    } finally {
      await f.close();
    }
  }

  Stream<T> _readRecordsFromHandle<T>(
      RandomAccessFile f,
      T Function(String keyText, List<int> originalData,
              List<(int, int, int, int)> segments)
          recordProcessor,
      {bool readData = true}) async* {
    await f.setPosition(_recordBlockOffset);

    final recordBlockInfoList = await _readRecordBlockInfoFromHandle(f);
    final totalDecompressedSize = recordBlockInfoList.fold<int>(
        0, (total, blockInfo) => total + blockInfo.$2);
    var offset = 0;
    var keyIndex = 0;
    var recordBlockOffset = _recordBlockOffset + _numberWidth * 4;
    recordBlockOffset += recordBlockInfoList.length * _numberWidth * 2;
    _PendingRecord? pendingRecord;

    for (var blockIndex = 0;
        blockIndex < recordBlockInfoList.length;
        blockIndex++) {
      final (compressedSize, _) = recordBlockInfoList[blockIndex];
      final recordBlock = _decodeBlock(await f.read(compressedSize));
      final blockStart = offset;
      final blockEnd = blockStart + recordBlock.length;

      if (pendingRecord != null) {
        if (pendingRecord.end < blockStart) {
          throw FormatException("Record offset is out of order");
        }
        final endOffset = pendingRecord.end < blockEnd
            ? pendingRecord.end - blockStart
            : recordBlock.length;
        if (endOffset > 0) {
          if (readData) {
            pendingRecord.data.addAll(recordBlock.sublist(0, endOffset));
          }
          pendingRecord.segments
              .add((recordBlockOffset, 0, endOffset, compressedSize));
        }
        if (pendingRecord.end <= blockEnd) {
          final completedRecord = pendingRecord;
          pendingRecord = null;
          yield recordProcessor(completedRecord.keyText, completedRecord.data,
              completedRecord.segments);
        }
      }

      while (keyIndex < _keyList.length) {
        final (recordStart, keyText) = _keyList[keyIndex];
        if (recordStart >= blockEnd) {
          break;
        }
        if (recordStart < blockStart) {
          throw FormatException("Record offsets are not sorted");
        }

        final recordEnd = keyIndex < _keyList.length - 1
            ? _keyList[keyIndex + 1].$1
            : (blockIndex == recordBlockInfoList.length - 1
                ? blockEnd
                : totalDecompressedSize);
        if (recordEnd < recordStart) {
          throw FormatException("Record offsets are not sorted");
        }

        final startOffset = recordStart - blockStart;
        final endOffset =
            recordEnd < blockEnd ? recordEnd - blockStart : recordBlock.length;
        final segments = <(int, int, int, int)>[
          (recordBlockOffset, startOffset, endOffset, compressedSize),
        ];
        final originalData = readData
            ? recordBlock.sublist(startOffset, endOffset)
            : const <int>[];
        keyIndex++;

        if (recordEnd > blockEnd) {
          pendingRecord = _PendingRecord(keyText, recordEnd)
            ..segments.addAll(segments);
          if (readData) {
            pendingRecord.data.addAll(originalData);
          }
          break;
        }

        yield recordProcessor(keyText, originalData, segments);
      }

      offset = blockEnd;
      recordBlockOffset += compressedSize;
    }

    if (pendingRecord != null || keyIndex < _keyList.length) {
      throw FormatException("Record offsets exceed record blocks");
    }
  }

  List<(int, String)> _splitKeyBlock(List<int> keyBlock) {
    final List<(int, String)> keyList = [];
    final Uint8List bytes =
        keyBlock is Uint8List ? keyBlock : Uint8List.fromList(keyBlock);
    final width = _isUtf16 ? 2 : 1;
    final numberWidth = _numberWidth;

    for (var keyStartIndex = 0; keyStartIndex < bytes.length;) {
      // The corresponding record's offset in the record block.
      final keyId = _readNumber(bytes, numberWidth, keyStartIndex);
      final keyTextStart = keyStartIndex + numberWidth;

      // Find the terminator without allocating a sublist for every byte (or
      // UTF-16 code unit). MDict uses a zero byte for single-byte encodings
      // and two zero bytes for UTF-16 encodings.
      final keyEndIndex = width == 1
          ? _findByteTerminator(bytes, keyTextStart)
          : _findUtf16Terminator(bytes, keyTextStart);
      final hasTerminator = width == 1
          ? keyEndIndex < bytes.length
          : keyEndIndex + 1 < bytes.length;
      if (!hasTerminator) {
        throw const FormatException("Invalid key block terminator");
      }

      final keyEncoded = _sliceBytes(bytes, keyTextStart, keyEndIndex);
      final keyText = _decodeText(keyEncoded);

      keyStartIndex = keyEndIndex + width;
      keyList.add((keyId, keyText));
    }

    return keyList;
  }

  String _substituteStylesheet(String txt) {
    final regExp = RegExp(r'`\d+`');
    final txtList = txt.split(regExp);
    final txtTags = regExp.allMatches(txt).map((m) => m.group(0)!).toList();
    var txtStyled = txtList[0];

    for (var j = 0; j < txtTags.length; j++) {
      final p = txtList[j + 1];
      final txtTag = txtTags[j];
      final styleKey = txtTag.substring(1, txtTag.length - 1);
      final style = _stylesheet[styleKey];

      if (style != null) {
        if (p.isNotEmpty && p.endsWith('\n')) {
          txtStyled = "$txtStyled${style.$1}${p.trimRight()}${style.$2}\r\n";
        } else {
          txtStyled = "$txtStyled${style.$1}$p${style.$2}";
        }
      } else {
        txtStyled = "$txtStyled$txtTag$p";
      }
    }
    return txtStyled;
  }

  String _treatRecordMdxData(List<int> data) {
    var dataReturned = _stripNul(_decodeText(data));

    if (_stylesheet.isNotEmpty) {
      dataReturned = _substituteStylesheet(dataReturned);
    }

    return dataReturned;
  }
}

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
  /// [readOneMdx] and [readOneMdd] to reconstruct the complete record.
  final List<(int, int, int, int)> segments;

  /// Creates a new [RecordOffsetInfo] instance.
  const RecordOffsetInfo(this.keyText, this.recordBlockOffset, this.startOffset,
      this.endOffset, this.compressedSize,
      {this.segments = const []});
}

class _PendingRecord {
  final String keyText;
  final int end;
  final List<int> data = [];
  final List<(int, int, int, int)> segments = [];

  _PendingRecord(this.keyText, this.end);
}

class _DictInitData {
  int? recordBlockOffset;

  // For _readKeys
  List<(int, String)>? keyList;
  int? numEntries;

  // For _readRecordBlockInfo
  List<(int, int)>? recordBlockInfoList;
  int? totalDecompressedSize;

  _DictInitData();
}

Map<String, dynamic> _importCacheIsolate(Map<String, dynamic> cacheData) {
  final keyList = (cacheData['keyList'] as List)
      .map((e) => (e[0] as int, e[1] as String))
      .toList();
  final numEntries = cacheData['numEntries'];
  final recordBlockOffset = cacheData['recordBlockOffset'];
  List<(int, int)>? recordBlockInfoList;
  if (cacheData['recordBlockInfoList'] != null) {
    recordBlockInfoList = (cacheData['recordBlockInfoList'] as List)
        .map((e) => (e[0] as int, e[1] as int))
        .toList();
  }
  final totalDecompressedSize = cacheData['totalDecompressedSize'];

  return {
    'keyList': keyList,
    'numEntries': numEntries,
    'recordBlockOffset': recordBlockOffset,
    'recordBlockInfoList': recordBlockInfoList,
    'totalDecompressedSize': totalDecompressedSize,
  };
}

Map<String, dynamic> _exportCacheIsolate(
    List<(int, String)> keyList,
    int numEntries,
    int recordBlockOffset,
    List<(int, int)>? recordBlockInfoList,
    int? totalDecompressedSize,
    String filePath,
    int fileSize,
    int fileModified) {
  return {
    'cacheVersion': _cacheVersion,
    'filePath': filePath,
    'fileSize': fileSize,
    'fileModified': fileModified,
    'keyList': keyList.map((e) => [e.$1, e.$2]).toList(),
    'numEntries': numEntries,
    'recordBlockOffset': recordBlockOffset,
    'recordBlockInfoList':
        recordBlockInfoList?.map((e) => [e.$1, e.$2]).toList(),
    'totalDecompressedSize': totalDecompressedSize,
  };
}

Future<_DictInitData> _initDictIsolate(
    String path,
    bool readKeys,
    bool readRecordBlockInfo,
    int keyBlockOffset,
    double version,
    int numberWidth,
    int encrypt,
    String encoding) async {
  final initData = _DictInitData();
  final reader = DictReader(path);
  reader._dict = File(path);
  reader._f = await reader._dict!.open();

  reader._keyBlockOffset = keyBlockOffset;
  reader._version = version;
  reader._numberWidth = numberWidth;
  reader._encrypt = encrypt;
  reader._encoding = encoding;
  reader._configureEncoding();

  if (readKeys) {
    initData.keyList = await reader._readKeys();
    initData.numEntries = reader.numEntries;
    initData.recordBlockOffset = reader._recordBlockOffset;
  } else if (readRecordBlockInfo) {
    await reader._skipKeys();
    initData.numEntries = reader.numEntries;
    initData.recordBlockOffset = reader._recordBlockOffset;
  }

  if (readRecordBlockInfo) {
    await reader._readRecordBlockInfo();
    initData.recordBlockInfoList = reader._recordBlockInfoList;
    initData.totalDecompressedSize = reader._totalDecompressedSize;
  }

  await reader.close();
  return initData;
}
