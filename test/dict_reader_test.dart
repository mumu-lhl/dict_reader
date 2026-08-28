import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:charset/charset.dart';
import 'package:dict_reader/dict_reader.dart';
import 'package:test/test.dart';

void _writeUint32BE(BytesBuilder builder, int value) {
  final bytes = ByteData(4)..setUint32(0, value, Endian.big);
  builder.add(bytes.buffer.asUint8List());
}

void _writeUint32LE(BytesBuilder builder, int value) {
  final bytes = ByteData(4)..setUint32(0, value, Endian.little);
  builder.add(bytes.buffer.asUint8List());
}

List<int> _block(List<int> payload) {
  final builder = BytesBuilder();
  _writeUint32LE(builder, 0);
  _writeUint32BE(builder, 0);
  builder.add(payload);
  return builder.toBytes();
}

List<int> _encode(String value, String encoding) {
  final normalizedEncoding = encoding.toUpperCase();
  if (normalizedEncoding == 'UTF-8') {
    return utf8.encode(value);
  }
  if (normalizedEncoding == 'UTF-16') {
    return const Utf16Encoder().encodeUtf16Le(value);
  }
  return Charset.getByName(encoding)!.encode(value);
}

Future<File> _createFixture(
  Directory directory, {
  String encoding = 'UTF-8',
  List<(String, String)> entries = const [
    ('alpha', 'A'),
    (r'$beta', 'B'),
  ],
  List<List<int>>? keyBytesOverride,
  List<List<int>>? valueBytesOverride,
  List<List<int>>? recordBlockPayloads,
  String extension = '.mdx',
}) async {
  final keyBytes = keyBytesOverride ??
      entries.map((entry) => _encode(entry.$1, encoding)).toList();
  final values = valueBytesOverride ??
      entries.map((entry) => _encode(entry.$2, encoding)).toList();
  final keyTerminator =
      encoding.toUpperCase().startsWith('UTF-16') ? [0, 0] : [0];

  final keyPayload = BytesBuilder();
  var recordOffset = 0;
  for (var i = 0; i < keyBytes.length; i++) {
    _writeUint32BE(keyPayload, recordOffset);
    keyPayload.add(keyBytes[i]);
    keyPayload.add(keyTerminator);
    recordOffset += values[i].length;
  }
  final keyBlock = _block(keyPayload.toBytes());

  final keyInfo = BytesBuilder();
  _writeUint32BE(keyInfo, entries.length);
  keyInfo.add([0, 0]);
  _writeUint32BE(keyInfo, keyBlock.length);
  _writeUint32BE(keyInfo, keyBlock.length - 8);

  final recordPayload = values.expand((value) => value).toList();
  final recordBlocks =
      (recordBlockPayloads ?? [recordPayload]).map(_block).toList();
  final recordBlockSize =
      recordBlocks.fold(0, (size, block) => size + block.length);
  final recordInfoSize = recordBlocks.length * 8;

  final header = utf8.encode(
      '<Dictionary><Encoding="$encoding" GeneratedByEngineVersion="1.0" Encrypted="No"/></Dictionary>\u0000');

  final file = BytesBuilder();
  _writeUint32BE(file, header.length);
  file.add(header);
  _writeUint32LE(file, 0);

  _writeUint32BE(file, 1); // number of key blocks
  _writeUint32BE(file, entries.length);
  _writeUint32BE(file, keyInfo.length);
  _writeUint32BE(file, keyBlock.length);
  file.add(keyInfo.toBytes());
  file.add(keyBlock);

  _writeUint32BE(file, recordBlocks.length);
  _writeUint32BE(file, entries.length);
  _writeUint32BE(file, recordInfoSize);
  _writeUint32BE(file, recordBlockSize);
  for (final recordBlock in recordBlocks) {
    _writeUint32BE(file, recordBlock.length);
    _writeUint32BE(file, recordBlock.length - 8);
  }
  for (final recordBlock in recordBlocks) {
    file.add(recordBlock);
  }

  final result = File('${directory.path}/fixture$extension');
  return result.writeAsBytes(file.toBytes());
}

void main() {
  test('keeps record order when keys use MDict ordering', () async {
    final directory =
        await Directory.systemTemp.createTemp('dict_reader_test_');
    addTearDown(() => directory.delete(recursive: true));
    final file = await _createFixture(directory);

    final reader = DictReader(file.path);
    await reader.initDict();
    addTearDown(reader.close);

    final records = <(String, String)>[];
    await for (final record in reader.readWithMdxData()) {
      records.add((record.keyText, record.data));
    }

    expect(records, [('alpha', 'A'), (r'$beta', 'B')]);
    final offset = await reader.locate(r'$beta');
    expect(offset, isNotNull);
    expect(await reader.readOneMdx(offset!), 'B');
  });

  test('handles records crossing record block boundaries', () async {
    final directory =
        await Directory.systemTemp.createTemp('dict_reader_boundary_test_');
    addTearDown(() => directory.delete(recursive: true));
    final file = await _createFixture(
      directory,
      entries: [('alpha', 'ABCDE'), (r'$beta', 'FG')],
      recordBlockPayloads: [
        utf8.encode('ABC'),
        utf8.encode('DEFG'),
      ],
    );

    final reader = DictReader(file.path);
    await reader.initDict();
    addTearDown(reader.close);

    final records = await reader.readWithMdxData().toList();
    expect(records.map((record) => (record.keyText, record.data)), [
      ('alpha', 'ABCDE'),
      (r'$beta', 'FG'),
    ]);
    final offset = await reader.locate('alpha');
    expect(offset, isNotNull);
    expect(await reader.readOneMdx(offset!), 'ABCDE');

    final offsets = await reader.readWithOffset().toList();
    expect(offsets.first.segments, hasLength(2));
    expect(await reader.readOneMdx(offsets.first), 'ABCDE');

    final legacyRecords = await reader.read(true).toList();
    expect(legacyRecords, [
      ('alpha', 'ABCDE'),
      (r'$beta', 'FG'),
    ]);
  });

  test('decodes the header-specified encoding and strips NUL padding',
      () async {
    final directory =
        await Directory.systemTemp.createTemp('dict_reader_encoding_test_');
    addTearDown(() => directory.delete(recursive: true));
    final file = await _createFixture(
      directory,
      encoding: 'GB18030',
      entries: [('你好', '定义\u0000')],
    );

    final reader = DictReader(file.path);
    await reader.initDict();
    addTearDown(reader.close);

    final records = await reader.readWithMdxData().toList();
    expect(
        records.map((record) => (record.keyText, record.data)), [('你好', '定义')]);
  });

  test('ignores malformed UTF-8 bytes in records', () async {
    final directory =
        await Directory.systemTemp.createTemp('dict_reader_malformed_test_');
    addTearDown(() => directory.delete(recursive: true));
    final file = await _createFixture(
      directory,
      entries: [('alpha', 'ignored')],
      valueBytesOverride: [
        [0xff, 0]
      ],
    );

    final reader = DictReader(file.path);
    await reader.initDict();
    addTearDown(reader.close);

    final records = await reader.readWithMdxData().toList();
    expect(records.single.data, '');
  });

  test('recognizes uppercase MDX extensions', () async {
    final directory =
        await Directory.systemTemp.createTemp('dict_reader_extension_test_');
    addTearDown(() => directory.delete(recursive: true));
    final file = await _createFixture(
      directory,
      extension: '.MDX',
      entries: [('alpha', 'A')],
    );

    final reader = DictReader(file.path);
    await reader.initDict();
    addTearDown(reader.close);

    final record = await reader.read(true).first;
    expect(record.$2, 'A');
  });

  test('preserves MDD resource keys', () async {
    final directory =
        await Directory.systemTemp.createTemp('dict_reader_mdd_test_');
    addTearDown(() => directory.delete(recursive: true));
    final file = await _createFixture(
      directory,
      encoding: 'UTF-16',
      extension: '.MDD',
      entries: [(r'\\foo\\bar', 'A')],
    );

    final reader = DictReader(file.path);
    await reader.initDict();
    addTearDown(reader.close);

    final records = await reader.readWithMddData().toList();
    expect(records.single.keyText, r'\\foo\\bar');
    expect(records.single.data, [0x41, 0x00]);
  });

  test('loads the header when keys are requested without readHeader', () async {
    final directory =
        await Directory.systemTemp.createTemp('dict_reader_flags_test_');
    addTearDown(() => directory.delete(recursive: true));
    final file = await _createFixture(directory);

    final reader = DictReader(file.path);
    await reader.initDict(readHeader: false);
    addTearDown(reader.close);

    expect((await reader.readWithMdxData().toList()).length, 2);
  });

  test('can initialize repeatedly on the same open reader', () async {
    final directory =
        await Directory.systemTemp.createTemp('dict_reader_repeat_init_test_');
    addTearDown(() => directory.delete(recursive: true));
    final file = await _createFixture(directory);

    final reader = DictReader(file.path);
    await reader.initDict(readKeys: false, readRecordBlockInfo: false);
    await reader.initDict();
    addTearDown(reader.close);

    expect((await reader.readWithMdxData().toList()).length, 2);
  });

  test('can read record block metadata without loading keys', () async {
    final directory =
        await Directory.systemTemp.createTemp('dict_reader_record_info_test_');
    addTearDown(() => directory.delete(recursive: true));
    final file = await _createFixture(directory);

    final reader = DictReader(file.path);
    var callbackCalled = false;
    reader.setOnRecordBlockInfoRead(() => callbackCalled = true);
    await reader.initDict(readKeys: false);
    addTearDown(reader.close);

    expect(callbackCalled, isTrue);
  });

  test('can be initialized again after close', () async {
    final directory =
        await Directory.systemTemp.createTemp('dict_reader_reinit_test_');
    addTearDown(() => directory.delete(recursive: true));
    final file = await _createFixture(directory);

    final reader = DictReader(file.path);
    await reader.initDict();
    await reader.close();
    await reader.initDict();
    addTearDown(reader.close);

    expect((await reader.readWithMdxData().toList()).length, 2);
  });

  test('imports cache into a fresh reader', () async {
    final directory =
        await Directory.systemTemp.createTemp('dict_reader_cache_test_');
    addTearDown(() => directory.delete(recursive: true));
    final file = await _createFixture(directory);

    final source = DictReader(file.path);
    await source.initDict();
    final cache = await source.exportCache();
    await source.close();

    final reader = DictReader(file.path);
    await reader.importCache(cache);
    addTearDown(reader.close);

    final offset = await reader.locate('alpha');
    expect(offset, isNotNull);
    expect(await reader.readOneMdx(offset!), 'A');
  });
}
