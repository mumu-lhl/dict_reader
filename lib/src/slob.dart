import "dart:io";
import "dart:typed_data";

import "dict_reader_base.dart";

class Slob implements DictReaderBase {
  static const _char = 1;
  static const _short = 2;
  static const _int = 4;
  static const _long = 8;

  late final File _file;
  late final RandomAccessFile _raf;

  late final int _storeOffset;

  final Map<int, String> _contentTypes = {};
  final Map<String, String> tags = {};

  Slob(String path) {
    _file = File(path);
  }

  @override
  Future<void> close() async {
    await _raf.close();
  }

  @override
  Future<void> init() async {
    _raf = await _file.open();

    await _readHeader();
  }

  @override
  Stream<(String, dynamic)> read([bool returnData = false]) async* {
    // position
    final positionCount =
        ByteData.sublistView(await _raf.read(_int)).getInt32(0);
    final offsets = <int>[];
    for (var i = 0; i < positionCount; i++) {
      offsets.add(ByteData.sublistView(await _raf.read(_long)).getInt64(0));
    }

    // ref
    for (var i = 0; i < positionCount; i++) {
      // key
      final keyCount =
          ByteData.sublistView(await _raf.read(_short)).getInt16(0);
      final key = String.fromCharCodes(await _raf.read(keyCount));

      // bin index
      final binIndex = ByteData.sublistView(await _raf.read(_int)).getInt32(0);

      // item index
      final itemIndex =
          ByteData.sublistView(await _raf.read(_short)).getInt16(0);

      // fragment
      await _raf.read(_char);

      print("$key, $binIndex, $itemIndex, ${offsets[i]}");
    }
  }

  @override
  Future<dynamic> readOne(
      int offset, int startOffset, int endOffset, int compressedSize) async {
    await _raf.setPosition(_storeOffset);
  }

  Future<dynamic> readStore() async {
    await _raf.setPosition(_storeOffset);

    // position
    final offsetCount = ByteData.sublistView(await _raf.read(_int)).getInt32(0);
    final offsets = <int>[];
    for (var i = 0; i < offsetCount; i++) {
      offsets.add(ByteData.sublistView(await _raf.read(_long)).getInt64(0));
    }

    // store item
    final contentTypeIdsCount =
        ByteData.sublistView(await _raf.read(_int)).getInt32(0);
    final contentTypeIds = await _raf.read(contentTypeIdsCount);

    final storageBinCount =
        ByteData.sublistView(await _raf.read(_int)).getInt32(0);
    final storageBin = await _raf.read(storageBinCount);

    final content = zlib.decode(storageBin);
    for (var j = 0; j < content.length;) {
      final count =
          ByteData.sublistView(Uint8List.fromList(content), j).getInt32(0);
      print(count);
      final c = content.sublist(j + _int, j + _int + count);
      print(String.fromCharCodes(c));
      break;
    }
  }

  Future<void> _readContentTypes() async {
    final number = (await _raf.read(_char))[0];
    for (var i = 0; i < number; i++) {
      final contentTypeCount =
          ByteData.sublistView(await _raf.read(_short)).getInt16(0);
      final contentType =
          String.fromCharCodes(await _raf.read(contentTypeCount));
      _contentTypes[i] = contentType;
    }
  }

  Future<void> _readHeader() async {
    // magic
    await _raf.read(8);

    // uuid
    await _raf.read(16);

    // encoding
    await _readSequence(_char);

    // compression
    await _readSequence(_char);

    // tags
    await _readTags();

    // content types
    await _readContentTypes();

    // blob count
    await _raf.read(_int);

    // store offset
    _storeOffset = ByteData.sublistView(await _raf.read(_long)).getInt64(0);

    // size
    await _raf.read(_long);
  }

  Future<Uint8List> _readSequence(int size) async {
    final bytes = await _raf.read(size);
    final count = bytes[0];
    final contentBytes = await _raf.read(count);
    return contentBytes;
  }

  Future<void> _readTags() async {
    final number = (await _raf.read(_char))[0];
    for (var i = 0; i < number; i++) {
      final tagCount = (await _raf.read(_char))[0];
      final tag = String.fromCharCodes(await _raf.read(tagCount));
      final tagValueCount = (await _raf.read(_char))[0];
      final tagValue = String.fromCharCodes(await _raf.read(tagValueCount));
      tags[tag] = tagValue;
    }
  }
}
