import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

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

Future<File> _createFixture(Directory directory) async {
  final keys = <String>['alpha', r'$beta'];
  final values = <List<int>>[
    utf8.encode('A'),
    utf8.encode('B'),
  ];

  final keyPayload = BytesBuilder();
  for (var i = 0; i < keys.length; i++) {
    _writeUint32BE(
        keyPayload, values.take(i).fold(0, (sum, value) => sum + value.length));
    keyPayload.add(utf8.encode(keys[i]));
    keyPayload.addByte(0);
  }
  final keyBlock = _block(keyPayload.toBytes());

  final keyInfo = BytesBuilder();
  _writeUint32BE(keyInfo, keys.length);
  keyInfo.add([0, 0]);
  _writeUint32BE(keyInfo, keyBlock.length);
  _writeUint32BE(keyInfo, keyBlock.length - 8);

  final recordPayload = values.expand((value) => value).toList();
  final recordBlock = _block(recordPayload);
  final recordInfoSize = 8;

  final header = utf8.encode(
      '<Dictionary><Encoding="UTF-8" GeneratedByEngineVersion="1.0" Encrypted="No"/></Dictionary>\u0000');

  final file = BytesBuilder();
  _writeUint32BE(file, header.length);
  file.add(header);
  _writeUint32LE(file, 0);

  _writeUint32BE(file, 1); // number of key blocks
  _writeUint32BE(file, keys.length);
  _writeUint32BE(file, keyInfo.length);
  _writeUint32BE(file, keyBlock.length);
  file.add(keyInfo.toBytes());
  file.add(keyBlock);

  _writeUint32BE(file, 1); // number of record blocks
  _writeUint32BE(file, keys.length);
  _writeUint32BE(file, recordInfoSize);
  _writeUint32BE(file, recordBlock.length);
  _writeUint32BE(file, recordBlock.length);
  _writeUint32BE(file, recordPayload.length);
  file.add(recordBlock);

  final result = File('${directory.path}/fixture.mdx');
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
}
