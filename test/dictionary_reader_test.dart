import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dict_reader/dict_reader.dart';
import 'package:test/test.dart';

import 'stardict_fixture.dart';
import 'zim_fixture.dart';

// Helper for writing a minimal MDX fixture
void _writeUint32BE(BytesBuilder builder, int value) {
  builder.add([
    (value >> 24) & 0xff,
    (value >> 16) & 0xff,
    (value >> 8) & 0xff,
    value & 0xff,
  ]);
}

void _writeUint32LE(BytesBuilder builder, int value) {
  builder.add([
    value & 0xff,
    (value >> 8) & 0xff,
    (value >> 16) & 0xff,
    (value >> 24) & 0xff,
  ]);
}

List<int> _block(List<int> payload) {
  final builder = BytesBuilder();
  _writeUint32LE(builder, 0); // compression method 0 = uncompressed
  _writeUint32LE(builder, 0);
  builder.add(payload);
  return builder.toBytes();
}

Future<File> _createMdxFixture(
  Directory dir,
  String name, {
  List<(String, String)> entries = const [
    ('apple', '<b>apple</b>: a red fruit'),
    ('banana', '<b>banana</b>: a yellow fruit'),
  ],
}) async {
  final keyBytes = entries.map((e) => utf8.encode(e.$1)).toList();
  final values = entries.map((e) => utf8.encode(e.$2)).toList();

  final keyPayload = BytesBuilder();
  var recordOffset = 0;
  for (var i = 0; i < keyBytes.length; i++) {
    _writeUint32BE(keyPayload, recordOffset);
    keyPayload.add(keyBytes[i]);
    keyPayload.addByte(0);
    recordOffset += values[i].length;
  }
  final keyBlock = _block(keyPayload.toBytes());

  final keyInfo = BytesBuilder();
  _writeUint32BE(keyInfo, entries.length);
  keyInfo.add([0, 0]);
  _writeUint32BE(keyInfo, keyBlock.length);
  _writeUint32BE(keyInfo, keyBlock.length - 8);

  final recordPayload = values.expand((v) => v).toList();
  final recordBlock = _block(recordPayload);

  final header = utf8.encode(
    '<Dictionary Title="Test MDX Dict" Encoding="UTF-8" GeneratedByEngineVersion="1.0" Encrypted="No"/>\u0000',
  );

  final file = BytesBuilder();
  _writeUint32BE(file, header.length);
  file.add(header);
  _writeUint32LE(file, 0);

  _writeUint32BE(file, 1);
  _writeUint32BE(file, entries.length);
  _writeUint32BE(file, keyInfo.length);
  _writeUint32BE(file, keyBlock.length);
  file.add(keyInfo.toBytes());
  file.add(keyBlock);

  _writeUint32BE(file, 1);
  _writeUint32BE(file, entries.length);
  _writeUint32BE(file, 8);
  _writeUint32BE(file, recordBlock.length);
  _writeUint32BE(file, recordBlock.length);
  _writeUint32BE(file, recordBlock.length - 8);
  file.add(recordBlock);

  final result = File('${dir.path}/$name.mdx');
  return result.writeAsBytes(file.toBytes());
}

Future<File> _createMddFixture(
  Directory dir,
  String name, {
  List<(String, List<int>)> resources = const [
    (r'\logo.png', [0x89, 0x50, 0x4e, 0x47]),
  ],
}) async {
  final keyBytes = resources.map((e) => utf8.encode(e.$1)).toList();
  final values = resources.map((e) => e.$2).toList();

  final keyPayload = BytesBuilder();
  var recordOffset = 0;
  for (var i = 0; i < keyBytes.length; i++) {
    _writeUint32BE(keyPayload, recordOffset);
    keyPayload.add(keyBytes[i]);
    keyPayload.addByte(0);
    recordOffset += values[i].length;
  }
  final keyBlock = _block(keyPayload.toBytes());

  final keyInfo = BytesBuilder();
  _writeUint32BE(keyInfo, resources.length);
  keyInfo.add([0, 0]);
  _writeUint32BE(keyInfo, keyBlock.length);
  _writeUint32BE(keyInfo, keyBlock.length - 8);

  final recordPayload = values.expand((v) => v).toList();
  final recordBlock = _block(recordPayload);

  final header = utf8.encode(
    '<Dictionary Title="Test MDD" Encoding="UTF-8" GeneratedByEngineVersion="1.0" Encrypted="No"/>\u0000',
  );

  final file = BytesBuilder();
  _writeUint32BE(file, header.length);
  file.add(header);
  _writeUint32LE(file, 0);

  _writeUint32BE(file, 1);
  _writeUint32BE(file, resources.length);
  _writeUint32BE(file, keyInfo.length);
  _writeUint32BE(file, keyBlock.length);
  file.add(keyInfo.toBytes());
  file.add(keyBlock);

  _writeUint32BE(file, 1);
  _writeUint32BE(file, resources.length);
  _writeUint32BE(file, 8);
  _writeUint32BE(file, recordBlock.length);
  _writeUint32BE(file, recordBlock.length);
  _writeUint32BE(file, recordBlock.length - 8);
  file.add(recordBlock);

  final result = File('${dir.path}/$name.mdd');
  return result.writeAsBytes(file.toBytes());
}

void main() {
  late Directory dir;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('unified_dict_test_');
  });

  tearDown(() async {
    await dir.delete(recursive: true);
  });

  group('DictionaryReader unified interface with StarDict', () {
    test('opens and queries StarDict via DictionaryReader', () async {
      final builder = StarDictFixtureBuilder()
        ..add('apple', [
          ('m', 'a fruit with red skin'),
          ('t', "'æpl"),
        ])
        ..add('banana', [('m', 'a long yellow fruit')]);
      final base = await builder.write(dir, 'test_sd');

      // Open via DictionaryReader.open
      final DictionaryReader reader = await DictionaryReader.open('$base.ifo');

      expect(reader.title, 'Test Dictionary');
      expect(reader.wordCount, 2);
      expect(await reader.exist('apple'), isTrue);
      expect(await reader.exist('orange'), isFalse);

      final hits = reader.search('ap');
      expect(hits, ['apple']);

      final articles = await reader.lookup('apple');
      expect(articles, hasLength(1));
      final article = articles.single;
      expect(article.headword, 'apple');
      expect(article.format, 'stardict');
      expect(article.mimeType, 'text/plain');
      expect(await article.readText(), contains('a fruit with red skin'));
      expect(await article.readText(), contains("'æpl"));

      await reader.close();
    });
  });

  group('DictionaryReader unified interface with ZIM', () {
    test('opens and queries ZIM via DictionaryReader', () async {
      final builder = ZimFixtureBuilder()
        ..addMetadata('Title', 'Wiki Test')
        ..addArticle(
            'apple', 'apple', '<html><body><h1>Apple</h1></body></html>')
        ..addResource('img/logo.png', [1, 2, 3, 4], 'image/png');
      final zimPath = await builder.write(dir, 'test_zim');

      final DictionaryReader reader = await DictionaryReader.open(zimPath);

      expect(reader.title, 'Wiki Test');
      expect(reader.wordCount, 1);
      expect(await reader.exist('apple'), isTrue);
      expect(await reader.exist('banana'), isFalse);

      final articles = await reader.lookup('apple');
      expect(articles, hasLength(1));
      final article = articles.single;
      expect(article.headword, 'apple');
      expect(article.format, 'zim');
      expect(article.mimeType, 'text/html');
      expect(await article.readText(), contains('<h1>Apple</h1>'));

      // Resource lookup via unified interface
      final res = await reader.getResource('img/logo.png');
      expect(res, [1, 2, 3, 4]);

      await reader.close();
    });
  });

  group('DictionaryReader unified interface with MDX and MDD', () {
    test('opens and queries MDX with companion MDD via DictionaryReader',
        () async {
      await _createMdxFixture(dir, 'test_dict');
      await _createMddFixture(dir, 'test_dict');

      // Auto-discovers test_dict.mdd because base name matches
      final DictionaryReader reader =
          await DictionaryReader.open('${dir.path}/test_dict.mdx');

      expect(reader.title, 'Test MDX Dict');
      expect(reader.wordCount, 2);
      expect(await reader.exist('apple'), isTrue);
      expect(await reader.exist('pear'), isFalse);

      final suggestions = reader.search('ba');
      expect(suggestions, ['banana']);

      final articles = await reader.lookup('apple');
      expect(articles, hasLength(1));
      final article = articles.single;
      expect(article.headword, 'apple');
      expect(article.format, 'mdx');
      expect(article.mimeType, 'text/html');
      expect(await article.readText(), contains('<b>apple</b>'));

      // Resource lookup through auto-attached MDD
      final logo = await reader.getResource('logo.png');
      expect(logo, [0x89, 0x50, 0x4e, 0x47]);

      await reader.close();
    });
  });
}
