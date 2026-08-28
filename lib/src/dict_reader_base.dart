import "dart:convert";
import "dart:io";
import "dart:isolate";
import "dart:typed_data";

import "package:blockchain_utils/crypto/crypto/hash/hash.dart";
import "package:charset/charset.dart";
import "package:collection/collection.dart";
import "package:html_unescape/html_unescape.dart";

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

int _readByte(Uint8List buffer, int byteWidth, [int start = 0]) {
  final byteBuffer = ByteData.view(buffer.buffer);
  if (byteWidth == 1) {
    return byteBuffer.getUint8(start);
  } else {
    return byteBuffer.getUint16(start);
  }
}

int _readNumber(Uint8List buffer, int numberWidth, [int start = 0]) {
  final byteBuffer = ByteData.view(buffer.buffer);
  if (numberWidth == 4) {
    return byteBuffer.getInt32(start, Endian.big);
  } else {
    return byteBuffer.getInt64(start, Endian.big);
  }
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
  File? _dict;
  late List<(int, String)> _keyList;
  late List<(int, String, int)> _lookupKeyList;
  late int _encrypt;
  RandomAccessFile? _f;
  List<(int, int)>? _recordBlockInfoList;
  int? _totalDecompressedSize;

  late Map<String, String> header;

  void Function()? _onHeaderRead;
  void Function()? _onRecordBlockInfoRead;

  /// [_path] File path
  DictReader(this._path) {
    _mdx = _path.substring(_path.lastIndexOf(".")) == ".mdx";
  }

  /// Initialize
  ///
  /// Will not read key if [readKey] is false to reduce initialization time.
  @Deprecated("Use initDict instead.")
  Future<void> init([bool readKey = true]) async {
    _dict = File(_path);
    _f = await _dict!.open();
    header = await _readHeader();
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
    if (_dict == null) {
      _dict = File(_path);
      _f = await _dict!.open();
    }

    if (readHeader) {
      header = await _readHeader();
    }

    if (readKeys) {
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

      _keyList = initData.keyList!;
      _rebuildLookupKeyList();
      numEntries = initData.numEntries!;
      _recordBlockOffset = initData.recordBlockOffset!;

      if (readRecordBlockInfo) {
        _recordBlockInfoList = initData.recordBlockInfoList;
        _totalDecompressedSize = initData.totalDecompressedSize;

        if (_onRecordBlockInfoRead != null) {
          _onRecordBlockInfoRead!();
        }
      }
    }
  }

  /// Closes the dictionary file.
  Future<void> close() async {
    await _f?.close();
    _f = null;
  }

  /// Exports the cache data as a map.
  ///
  /// This method extracts the key list, number of entries, record block offset,
  /// record block info list, and total decompressed size into a map, which can
  /// be used for caching. This operation is performed in an isolate.
  Future<Map<String, dynamic>> exportCache() {
    final keyList = _keyList;
    final numEntries = this.numEntries;
    final recordBlockOffset = _recordBlockOffset;
    final recordBlockInfoList = _recordBlockInfoList;
    final totalDecompressedSize = _totalDecompressedSize;
    return Isolate.run(() => _exportCacheIsolate(keyList, numEntries,
        recordBlockOffset, recordBlockInfoList, totalDecompressedSize));
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
  Future<void> importCache(Map<String, dynamic> cacheData) async {
    final importedData =
        await Isolate.run(() => _importCacheIsolate(cacheData));
    _keyList = importedData['keyList'] as List<(int, String)>;
    _rebuildLookupKeyList();
    numEntries = importedData['numEntries'];
    _recordBlockOffset = importedData['recordBlockOffset'];
    _recordBlockInfoList =
        importedData['recordBlockInfoList'] as List<(int, int)>?;
    _totalDecompressedSize = importedData['totalDecompressedSize'];
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
    final f = _f!;
    await f.setPosition(_recordBlockOffset);

    final numRecordBlocks = await _readNumberer(f);
    // number of entries
    await _readNumberer(f);

    // size of record block info
    await _readNumberer(f);
    // size of record block
    await _readNumberer(f);

    // record block info section
    final List<int> recordBlockLnfoList = [];

    for (var i = 0; i < numRecordBlocks; i++) {
      final compressedSize = await _readNumberer(f);
      // record block decompressed size
      await _readNumberer(f);

      recordBlockLnfoList.add(compressedSize);
    }

    // actual record block
    var offset = 0;
    var i = 0;
    var recordBlockOffset = await f.position();

    for (final compressedSize in recordBlockLnfoList) {
      final recordBlock = _decodeBlock(await f.read(compressedSize));

      // split record block according to the offset info from key block
      while (i < _keyList.length) {
        final (recordStart, keyText) = _keyList[i];

        // reach the end of current record block
        if (recordStart - offset >= recordBlock.length) {
          break;
        }

        // record end index
        int recordEnd;

        if (i < _keyList.length - 1) {
          recordEnd = _keyList[i + 1].$1;
        } else {
          recordEnd = recordBlock.length + offset;
        }

        i += 1;

        if (returnData) {
          final originalData =
              recordBlock.sublist(recordStart - offset, recordEnd - offset);
          final data = _mdx ? _treatRecordMdxData(originalData) : originalData;

          yield (keyText, data);
        } else {
          final startOffset = recordStart - offset;
          final endOffset = recordEnd - offset;
          yield (
            keyText,
            (recordBlockOffset, startOffset, endOffset, compressedSize)
          );
        }
      }

      offset += recordBlock.length;
      recordBlockOffset += compressedSize;
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
    final f = _f!;
    await f.setPosition(offset);

    final recordBlock = _decodeBlock(await f.read(compressedSize));
    final originalData = recordBlock.sublist(startOffset, endOffset);
    final data = _mdx ? _treatRecordMdxData(originalData) : originalData;

    return data;
  }

  /// Only reads a mdd file's one record.
  ///
  /// [recordOffsetInfo] is obtained from [readWithOffset].
  /// Returns `List<int>`.
  Future<List<int>> readOneMdd(RecordOffsetInfo recordOffsetInfo) async {
    final f = _f!;
    await f.setPosition(recordOffsetInfo.recordBlockOffset);

    final recordBlock =
        _decodeBlock(await f.read(recordOffsetInfo.compressedSize));
    final data = recordBlock.sublist(
        recordOffsetInfo.startOffset, recordOffsetInfo.endOffset);

    return data;
  }

  /// Only reads a mdx file's one record.
  ///
  /// [recordOffsetInfo] is obtained from [readWithOffset].
  /// Returns `String` if file format is mdx.
  /// Returns `List<int>` if file format is mdd.
  Future<String> readOneMdx(RecordOffsetInfo recordOffsetInfo) async {
    final f = _f!;
    await f.setPosition(recordOffsetInfo.recordBlockOffset);

    final recordBlock =
        _decodeBlock(await f.read(recordOffsetInfo.compressedSize));
    final data = _treatRecordMdxData(recordBlock.sublist(
        recordOffsetInfo.startOffset, recordOffsetInfo.endOffset));

    return data;
  }

  /// Reads records from an MDD file and returns a stream of [MddRecord] objects.
  ///
  /// Each [MddRecord] contains the key text and the raw MDD data (`List<int>`).
  Stream<MddRecord> readWithMddData() async* {
    yield* _readRecords((keyText, originalData, recordBlockOffset, startOffset,
        endOffset, compressedSize) {
      return MddRecord(keyText, originalData);
    });
  }

  /// Reads records from an MDX file and returns a stream of [MdxRecord] objects.
  ///
  /// Each [MdxRecord] contains the key text and the processed MDX data.
  Stream<MdxRecord> readWithMdxData() async* {
    yield* _readRecords((keyText, originalData, recordBlockOffset, startOffset,
        endOffset, compressedSize) {
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
    yield* _readRecords((keyText, originalData, recordBlockOffset, startOffset,
        endOffset, compressedSize) {
      return (RecordOffsetInfo(
          keyText, recordBlockOffset, startOffset, endOffset, compressedSize));
    });
  }

  /// Locates the position information of a key (word).
  ///
  /// This method can be used to get the content of a key after initialization.
  /// Returns `null` if the key is not found.
  Future<RecordOffsetInfo?> locate(String key) async {
    final keyIndex = binarySearch(_lookupKeyList, (0, key, 0),
        compare: (a, b) => a.$2.compareTo(b.$2));

    if (keyIndex < 0) {
      return null;
    }

    final physicalIndex = _lookupKeyList[keyIndex].$3;
    final recordStart = _keyList[physicalIndex].$1;
    final recordEnd = (physicalIndex < _keyList.length - 1)
        ? _keyList[physicalIndex + 1].$1
        : -1; // -1 indicates the last record

    final actualRecordEnd =
        (recordEnd == -1) ? _totalDecompressedSize! : recordEnd;

    // Locate the correct block
    int accumulatedDecompressedSize = 0;
    // The file offset of the first record block.
    var recordBlockFileOffset = _recordBlockOffset + _numberWidth * 4;
    recordBlockFileOffset += _recordBlockInfoList!.length * _numberWidth * 2;

    for (final blockInfo in _recordBlockInfoList!) {
      final compressedSize = blockInfo.$1;
      final decompressedSize = blockInfo.$2;

      if (recordStart < accumulatedDecompressedSize + decompressedSize) {
        final startOffset = recordStart - accumulatedDecompressedSize;
        var endOffset = actualRecordEnd - accumulatedDecompressedSize;
        if (endOffset > decompressedSize) {
          endOffset = decompressedSize;
        }
        return RecordOffsetInfo(
            key, recordBlockFileOffset, startOffset, endOffset, compressedSize);
      }

      accumulatedDecompressedSize += decompressedSize;
      recordBlockFileOffset += compressedSize;
    }

    return null; // Should not happen if key is in _keyList
  }

  /// Locates the position information of all occurrences of a key (word).
  ///
  /// This method can be used to get the content of a key after initialization.
  /// Returns an empty list if the key is not found.
  Future<List<RecordOffsetInfo>> locateAll(String key) async {
    final results = <RecordOffsetInfo>[];
    // Use lowerBound to find the first potential match.
    var keyIndex = lowerBound(_lookupKeyList, (0, key, 0),
        compare: (a, b) => a.$2.compareTo(b.$2));

    if (keyIndex == _lookupKeyList.length ||
        _lookupKeyList[keyIndex].$2 != key) {
      return [];
    }

    // Iterate through all keys that match
    while (keyIndex < _lookupKeyList.length &&
        _lookupKeyList[keyIndex].$2 == key) {
      final physicalIndex = _lookupKeyList[keyIndex].$3;
      final recordStart = _keyList[physicalIndex].$1;
      final recordEnd = (physicalIndex < _keyList.length - 1)
          ? _keyList[physicalIndex + 1].$1
          : -1; // -1 indicates the last record

      final actualRecordEnd =
          (recordEnd == -1) ? _totalDecompressedSize! : recordEnd;

      // Locate the correct block
      int accumulatedDecompressedSize = 0;
      // The file offset of the first record block.
      var recordBlockFileOffset = _recordBlockOffset + _numberWidth * 4;
      recordBlockFileOffset += _recordBlockInfoList!.length * _numberWidth * 2;

      for (final blockInfo in _recordBlockInfoList!) {
        final compressedSize = blockInfo.$1;
        final decompressedSize = blockInfo.$2;

        if (recordStart < accumulatedDecompressedSize + decompressedSize) {
          final startOffset = recordStart - accumulatedDecompressedSize;
          var endOffset = actualRecordEnd - accumulatedDecompressedSize;
          if (endOffset > decompressedSize) {
            endOffset = decompressedSize;
          }
          results.add(RecordOffsetInfo(key, recordBlockFileOffset, startOffset,
              endOffset, compressedSize));
          break; // Found the block for this key, move to the next key
        }

        accumulatedDecompressedSize += decompressedSize;
        recordBlockFileOffset += compressedSize;
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
    final firstMatchIndex = lowerBound(_lookupKeyList, (0, key, 0),
        compare: (a, b) => a.$2.compareTo(b.$2));

    return _collectMatches(_lookupKeyList, key, firstMatchIndex, limit);
  }

  /// Checks if a key (word) exists in the dictionary.
  ///
  /// Returns `true` if the key is found, otherwise `false`.
  bool exist(String key) {
    final keyIndex = binarySearch(_lookupKeyList, (0, key, 0),
        compare: (a, b) => a.$2.compareTo(b.$2));
    return keyIndex >= 0;
  }

  void _rebuildLookupKeyList() {
    _lookupKeyList = [
      for (var i = 0; i < _keyList.length; i++)
        (_keyList[i].$1, _keyList[i].$2, i),
    ];
    mergeSort(_lookupKeyList, compare: (a, b) {
      final keyComparison = a.$2.compareTo(b.$2);
      return keyComparison != 0 ? keyComparison : a.$3.compareTo(b.$3);
    });
  }

  /// Collects all matching keys starting from a given index.
  List<String> _collectMatches(
      List<(int, String, int)> list, String key, int startIndex, int? limit) {
    final matchedKeys = <String>[];
    for (var i = startIndex; i < list.length; i++) {
      if (limit != null && matchedKeys.length >= limit) {
        break;
      }
      final currentKey = list[i].$2;
      if (currentKey.startsWith(key)) {
        matchedKeys.add(currentKey);
      } else {
        // Since the list is sorted, we can stop as soon as we find a non-match.
        break;
      }
    }
    return matchedKeys;
  }

  List<int> _decodeBlock(List<int> block) {
    final byteBuffer =
        ByteData.view(Uint8List.fromList(block).sublist(0, 4).buffer);
    final info = byteBuffer.getUint32(0, Endian.little);
    final compressionMethod = info & 0xf;
    final data = block.sublist(8);

    List<int> decompressedBlock;

    if (compressionMethod == 0) {
      decompressedBlock = data;
    } else if (compressionMethod == 2) {
      decompressedBlock = zlib.decode(data);
    } else {
      throw "Compression method not supported";
    }

    return decompressedBlock;
  }

  List<(int, String)> _decodeKeyBlock(
      List<int> keyBlockCompressed, List<int> keyBlockInfoList) {
    final List<(int, String)> keyList = [];
    var i = 0;

    for (final compressedSize in keyBlockInfoList) {
      final keyBlock =
          _decodeBlock(keyBlockCompressed.sublist(i, i + compressedSize));
      keyList.addAll(_splitKeyBlock(keyBlock));
      i += compressedSize;
    }

    return keyList;
  }

  List<int> _decodeKeyBlockInfo(List<int> keyBlockInfoCompressed) {
    List<int> keyBlockInfo;

    if (_version >= 2.0) {
      if (_encrypt == 2) {
        final key = RIPEMD128
            .hash(keyBlockInfoCompressed.sublist(4, 8) + [149, 54, 0, 0]);
        keyBlockInfoCompressed = keyBlockInfoCompressed.sublist(0, 8) +
            _fastDecrypt(Uint8List.fromList(keyBlockInfoCompressed.sublist(8)),
                Uint8List.fromList(key));
      }

      keyBlockInfo = zlib.decode(keyBlockInfoCompressed.sublist(8));
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
      final textHeadSize = _readByte(
          Uint8List.fromList(keyBlockInfo.sublist(i, i + byteWidth)),
          byteWidth);
      i += byteWidth;

      // text head
      if (_encoding != "UTF-16") {
        i += textHeadSize + textTerm;
      } else {
        i += (textHeadSize + textTerm) * 2;
      }

      // text tail size
      final textTailSize = _readByte(
          Uint8List.fromList(keyBlockInfo.sublist(i, i + byteWidth)),
          byteWidth);
      i += byteWidth;

      // text tail
      if (_encoding != "UTF-16") {
        i += textTailSize + textTerm;
      } else {
        i += (textTailSize + textTerm) * 2;
      }

      // key block compressed size
      final keyBlockCompressedSize = _readNumber(
          Uint8List.fromList(keyBlockInfo.sublist(i, i + _numberWidth)),
          _numberWidth);
      i += _numberWidth;
      // key block decompressed size
      _readNumber(Uint8List.fromList(keyBlockInfo.sublist(i, i + _numberWidth)),
          _numberWidth);
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

  Future<Map<String, String>> _readHeader() async {
    final f = _f!;
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
    if (["GBK", "GB2312"].contains(encoding)) {
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

    if (_onHeaderRead != null) {
      _onHeaderRead!();
    }

    return tags;
  }

  Future<List<(int, String)>> _readKeys() async {
    final f = _f!;
    await f.setPosition(_keyBlockOffset);

    // number of key blocks
    await _readNumberer(f);

    // number of entries
    numEntries = await _readNumberer(f);

    // number of bytes of key block info after decompression
    if (_version >= 2.0) {
      await f.read(_numberWidth);
    }

    // number of bytes of key block info
    final keyBlockInfoSize = await _readNumberer(f);
    // number of bytes of key block
    final keyBlockSize = await _readNumberer(f);

    if (_version >= 2.0) {
      await f.read(4);
    }

    final bytes = await f.read(keyBlockInfoSize);
    List<int> keyBlockInfoList = _decodeKeyBlockInfo(bytes);

    // read key block
    final List<int> keyBlockCompressed = List.from(await f.read(keyBlockSize));

    // extract key block
    final keyList = _decodeKeyBlock(keyBlockCompressed, keyBlockInfoList);

    _recordBlockOffset = await f.position();

    return keyList;
  }

  Future<int> _readNumberer(RandomAccessFile file, [int? numberWidth]) async {
    numberWidth ??= _numberWidth;
    final bytes = await file.read(numberWidth);

    if (numberWidth == 4) {
      return ByteData.sublistView(bytes).getInt32(0);
    } else {
      return ByteData.sublistView(bytes).getInt64(0);
    }
  }

  Future<void> _readRecordBlockInfo() async {
    final f = _f!;
    await f.setPosition(_recordBlockOffset);

    final numRecordBlocks = await _readNumberer(f);
    await _readNumberer(f); // number of entries
    await _readNumberer(f); // size of record block info
    await _readNumberer(f); // size of record block

    // Read record block info section
    _recordBlockInfoList = [];
    _totalDecompressedSize = 0;
    for (var i = 0; i < numRecordBlocks; i++) {
      final compressedSize = await _readNumberer(f);
      final decompressedSize = await _readNumberer(f);
      _recordBlockInfoList!.add((compressedSize, decompressedSize));
      _totalDecompressedSize = _totalDecompressedSize! + decompressedSize;
    }
  }

  Stream<T> _readRecords<T>(
      T Function(String keyText, List<int> originalData, int recordBlockOffset,
              int startOffset, int endOffset, int compressedSize)
          recordProcessor) async* {
    final f = _f!;
    await f.setPosition(_recordBlockOffset);

    final numRecordBlocks = await _readNumberer(f);
    // number of entries
    await _readNumberer(f);

    // size of record block info
    await _readNumberer(f);
    // size of record block
    await _readNumberer(f);

    // record block info section
    final List<int> recordBlockLnfoList = [];

    for (var i = 0; i < numRecordBlocks; i++) {
      final compressedSize = await _readNumberer(f);
      // record block decompressed size
      await _readNumberer(f);

      recordBlockLnfoList.add(compressedSize);
    }

    // actual record block
    var offset = 0;
    var i = 0;
    var recordBlockOffset = await f.position();

    for (final compressedSize in recordBlockLnfoList) {
      final recordBlock = _decodeBlock(await f.read(compressedSize));

      // split record block according to the offset info from key block
      while (i < _keyList.length) {
        final (recordStart, keyText) = _keyList[i];

        // reach the end of current record block
        if (recordStart - offset >= recordBlock.length) {
          break;
        }

        // record end index
        int recordEnd;

        if (i < _keyList.length - 1) {
          recordEnd = _keyList[i + 1].$1;
        } else {
          recordEnd = recordBlock.length + offset;
        }

        i += 1;

        final startOffset = recordStart - offset;
        final endOffset = recordEnd - offset;
        final originalData = recordBlock.sublist(startOffset, endOffset);

        yield recordProcessor(keyText, originalData, recordBlockOffset,
            startOffset, endOffset, compressedSize);
      }

      offset += recordBlock.length;
      recordBlockOffset += compressedSize;
    }
  }

  List<(int, String)> _splitKeyBlock(List<int> keyBlock) {
    final List<(int, String)> keyList = [];

    for (var keyStartIndex = 0; keyStartIndex < keyBlock.length;) {
      // the corresponding record's offset in record block
      final keyId = _readNumber(
          Uint8List.fromList(
              keyBlock.sublist(keyStartIndex, keyStartIndex + _numberWidth)),
          _numberWidth);

      var width = 1;

      // key text ends with '\x00'
      if (_encoding == "UTF-16") {
        width = 2;
      }

      late int keyEndIndex;

      for (var i = keyStartIndex + _numberWidth;
          i < keyBlock.length;
          i += width) {
        final sublist = keyBlock.sublist(i, i + width);
        if (sublist.first == 0 && sublist.last == 0) {
          keyEndIndex = i;
          break;
        }
      }

      final keyEncoded =
          keyBlock.sublist(keyStartIndex + _numberWidth, keyEndIndex);
      String keyText;

      if (_encoding == "UTF-16") {
        keyText = Utf16Decoder().decodeUtf16Le(keyEncoded);

        if (!_mdx) {
          keyText = keyText.replaceAll("\\", "/");
          if (keyText[0] == "/") {
            keyText = keyText.substring(1);
          }
        }
      } else {
        keyText = utf8.decode(keyEncoded);
      }

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
    String dataReturned;

    if (_encoding == "UTF-16") {
      dataReturned = Utf16Decoder().decodeUtf16Le(data);
    } else {
      dataReturned = utf8.decode(data);
    }

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

  /// Creates a new [RecordOffsetInfo] instance.
  const RecordOffsetInfo(this.keyText, this.recordBlockOffset, this.startOffset,
      this.endOffset, this.compressedSize);
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
    int? totalDecompressedSize) {
  return {
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

  if (readKeys) {
    initData.keyList = await reader._readKeys();
    initData.numEntries = reader.numEntries;
    initData.recordBlockOffset = reader._recordBlockOffset;
    if (readRecordBlockInfo) {
      await reader._readRecordBlockInfo();
      initData.recordBlockInfoList = reader._recordBlockInfoList;
      initData.totalDecompressedSize = reader._totalDecompressedSize;
    }
  }

  await reader.close();
  return initData;
}
