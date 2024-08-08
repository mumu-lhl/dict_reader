import "dart:convert";
import "dart:io";
import "dart:typed_data";

import "package:charset/charset.dart";

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
  late File _dict;
  late List<(int, String)> _keyList;

  late Map<String, String> header;

  /// [_path] File path
  DictReader(this._path) {
    _mdx = _path.substring(_path.lastIndexOf(".")) == ".mdx";
  }

  /// Initialize
  init() async {
    _dict = File(_path);
    header = await _readHeader();
    _keyList = await _readKeys();
  }

  /// Reads records
  ///
  /// Returns `Stream<(String, String)` when file format is mdx.
  /// Returns `Stream<(String, List<int>)` when file format is mdd.
  Stream<(String, dynamic)> read() async* {
    RandomAccessFile f = await _dict.open();
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
        late int recordEnd;

        if (i < _keyList.length - 1) {
          recordEnd = _keyList[i + 1].$1;
        } else {
          recordEnd = recordBlock.length + offset;
        }

        i += 1;

        final data = _treatRecordData(
            recordBlock.sublist(recordStart - offset, recordEnd - offset));

        yield (keyText, data);
      }

      offset += recordBlock.length;
    }

    await f.close();
  }

  List<int> _decodeBlock(List<int> block) {
    final byteBuffer =
        ByteData.view(Uint8List.fromList(block).sublist(0, 4).buffer);
    final info = byteBuffer.getUint32(0, Endian.little);
    final compressionMethod = info & 0xf;
    final data = block.sublist(8);

    late List<int> decompressedBlock;

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
    late List<int> keyBlockInfo;

    if (_version >= 2.0) {
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
    RandomAccessFile f = await _dict.open();
    var headerBytesSize = await _readNumberer(f, 4);

    var contentBytes = await f.read(headerBytesSize);
    String content;
    _keyBlockOffset = headerBytesSize + 8;

    await f.close();

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
    encoding ??= "UTF-8";
    // GB18030 > GBK > GB2312
    if (["GBK", "GB2312"].contains(encoding)) {
      encoding = "GB18030";
    }
    _encoding = encoding;

    // stylesheet attribute if present takes form of:
    //   style_number # 1-255
    //   style_begin  # or ''
    //   style_end    # or ''
    // store stylesheet in dict in the form of
    // {'number' : ('style_begin', 'style_end')}
    final stylesheetString = tags["StyleSheet"];
    if (stylesheetString != null) {
      final lines = LineSplitter().convert(stylesheetString);
      for (int i = 0; i < lines.length; i += 3) {
        _stylesheet[lines[i]] = (lines[i + 1], lines[i + 2]);
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

    return tags;
  }

  Future<List<(int, String)>> _readKeys() async {
    RandomAccessFile f = await _dict.open();
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

    await f.close();

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
      late String keyText;

      if (_encoding == "UTF-16") {
        keyText = utf16.decode(keyEncoded);
      } else {
        keyText = utf8.decode(keyEncoded);
      }

      keyStartIndex = keyEndIndex + width;

      keyList.add((keyId, keyText));
    }

    return keyList;
  }

  String _substituteStylesheet(String txt) {
    // substitute stylesheet definition
    RegExp regExp = RegExp(r'`\d+`');
    List<String> txtList = txt.split(regExp);
    Iterable<Match> matches = regExp.allMatches(txt);
    List<String> txtTags = matches.map((match) => match.group(0)!).toList();
    var txtStyled = txtList[0];

    for (var i = 0; i < txtList.length - 1; i++) {
      final p = txtList.sublist(1)[i];
      final txtTag = txtTags[i];
      final style = _stylesheet[txtTag.substring(1, txtTag.length)];

      if (p != "" && p[p.length] == "\n") {
        txtStyled = "$txtStyled${style!.$1}${p.trimRight()}${style.$1}\r\n";
      } else {
        txtStyled = "$txtStyled${style!.$1}$p${style.$1}";
      }
    }

    return txtStyled;
  }

  dynamic _treatRecordData(List<int> data) {
    late dynamic dataReturned;

    if (_mdx) {
      if (_encoding == "UTF-16") {
        dataReturned = utf16.decode(data);
      } else {
        dataReturned = utf8.decode(data);
      }

      if (_stylesheet.isNotEmpty) {
        dataReturned = _substituteStylesheet(dataReturned);
      }
    } else {
      dataReturned = data;
    }

    return dataReturned;
  }
}
