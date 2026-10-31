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

  group('Streaming and Range Resource Access', () {
    test('streams resources and handles range requests in ZIM and MDD',
        () async {
      final builder = ZimFixtureBuilder()
        ..addMetadata('Title', 'Stream Test')
        ..addResource('media/audio.bin', [0, 1, 2, 3, 4, 5, 6, 7, 8, 9],
            'application/octet-stream');
      final zimPath = await builder.write(dir, 'stream_zim',
          compression: ZimCompression.none);

      final reader = await DictionaryReader.open(zimPath);
      final stream =
          await reader.getResourceStream('media/audio.bin', start: 2, end: 6);
      expect(stream, isNotNull);
      final chunks = await stream!.toList();
      final bytes = chunks.expand((c) => c).toList();
      expect(bytes, [2, 3, 4, 5]);

      await reader.close();
    });

    test('openRead on DictArticle returns range bytes', () async {
      await _createMdxFixture(dir, 'mdx_range');
      final reader = await DictionaryReader.open('${dir.path}/mdx_range.mdx');
      final articles = await reader.lookup('apple');
      final article = articles.single;

      final fullStream = await article.openRead();
      final fullBytes = (await fullStream.toList()).expand((c) => c).toList();
      expect(utf8.decode(fullBytes), contains('<b>apple</b>'));

      final sliceStream = await article.openRead(start: 3, end: 8);
      final sliceBytes = (await sliceStream.toList()).expand((c) => c).toList();
      expect(sliceBytes, fullBytes.sublist(3, 8));

      await reader.close();
    });
  });

  group('Full-text search', () {
    test('searchFulltext finds content across MDX, StarDict, and ZIM',
        () async {
      // 1. MDX
      await _createMdxFixture(dir, 'mdx_ft');
      final mdxReader = await DictionaryReader.open('${dir.path}/mdx_ft.mdx');
      final mdxResults = await mdxReader.searchFulltext('fruit');
      expect(mdxResults, hasLength(2));
      expect(mdxResults.first.snippet, contains('fruit'));
      await mdxReader.close();

      // 2. StarDict
      final sdBuilder = StarDictFixtureBuilder()
        ..add('apple', [('m', 'a round fruit with red or green skin')])
        ..add('banana', [('m', 'a curved yellow fruit')]);
      final sdBase = await sdBuilder.write(dir, 'sd_ft');
      final sdReader = await DictionaryReader.open('$sdBase.ifo');
      final sdResults = await sdReader.searchFulltext('curved');
      expect(sdResults, hasLength(1));
      expect(sdResults.single.article.headword, 'banana');
      expect(sdResults.single.snippet, contains('curved'));
      await sdReader.close();

      // 3. ZIM
      final zimBuilder = ZimFixtureBuilder()
        ..addArticle(
            'earth', 'Earth', '<p>Earth is the third planet from the Sun.</p>')
        ..addArticle(
            'mars', 'Mars', '<p>Mars is the fourth planet from the Sun.</p>');
      final zimPath = await zimBuilder.write(dir, 'zim_ft');
      final zimReader = await DictionaryReader.open(zimPath);
      final zimResults = await zimReader.searchFulltext('planet');
      expect(zimResults, hasLength(2));
      expect(zimResults.first.snippet, contains('planet'));
      await zimReader.close();
    });
  });

  group('ZIM .cidx export and import', () {
    test('exportCidx and importCidx round-trip matches the scanned reader',
        () async {
      final builder = ZimFixtureBuilder()
        ..addMetadata('Title', 'CIDX Zim Test')
        ..addArticle('cat', 'Cat', '<p>Feline animal</p>')
        ..addArticle('dog', 'Dog', '<p>Canine animal</p>')
        ..addRedirect('kitty', 'Kitty', 'cat');
      final zimPath = await builder.write(dir, 'cidx_test');

      final scanned = ZimReader(zimPath);
      await scanned.init();

      final cidxBytes = await scanned.exportCidx();
      expect(cidxBytes, isNotEmpty);

      // Open a fresh reader and import the cidx
      final imported = ZimReader(zimPath);
      await imported.importCidx(cidxBytes);

      expect(imported.title, scanned.title);
      expect(imported.wordCount, scanned.wordCount);
      expect(imported.words, scanned.words);
      expect(imported.exist('cat'), isTrue);
      expect(imported.exist('kitty'), isTrue);
      expect(imported.exist('dog'), isTrue);
      expect(imported.exist('wolf'), isFalse);

      final cat = await imported.lookup('cat');
      expect(await cat.single.readText(), contains('Feline'));

      final redirect = await imported.lookup('kitty');
      expect(await redirect.single.readText(), contains('Feline'));

      final hits = imported.search('c');
      expect(hits, ['Cat']);

      await scanned.close();
      await imported.close();
    });

    test('rejects stale .cidx if file modified or corrupted', () async {
      final builder = ZimFixtureBuilder()
        ..addMetadata('Title', 'Stale Test')
        ..addArticle('one', 'One', '1');
      final zimPath = await builder.write(dir, 'stale_test');

      final reader = ZimReader(zimPath);
      await reader.init();
      final cidxBytes = await reader.exportCidx();
      await reader.close();

      // Corrupt magic
      cidxBytes[0] = 0xff;
      final badReader = ZimReader(zimPath);
      expect(
        () async => badReader.importCidx(cidxBytes),
        throwsA(isA<FormatException>()),
      );
    });
  });

  group('ZIM Xapian full-text index inspection and extraction', () {
    test('detects Xapian index and extracts database files', () async {
      final builder = ZimFixtureBuilder()
        ..addMetadata('Title', 'Xapian Test')
        ..addArticle('solar_system', 'Solar System', '<p>Planets and stars</p>')
        ..addResource(
          'fulltext/xapian/iamglass',
          utf8.encode('iamglass\n'),
          'application/octet-stream+xapian',
          namespace: 'X',
        )
        ..addResource(
          'fulltext/xapian/postlist.glass',
          utf8.encode('postlist data'),
          'application/octet-stream+xapian',
          namespace: 'X',
        );
      final zimPath = await builder.write(dir, 'xapian_zim');

      final reader = ZimReader(zimPath);
      await reader.init();

      expect(reader.hasFulltextIndex, isTrue);
      expect(reader.fulltextIndexPaths, contains('X/fulltext/xapian/iamglass'));
      expect(reader.fulltextIndexPaths,
          contains('X/fulltext/xapian/postlist.glass'));

      final extractDir = Directory('${dir.path}/extracted_xapian');
      await reader.extractFulltextDatabase(extractDir);

      expect(File('${extractDir.path}/iamglass').existsSync(), isTrue);
      expect(
        await File('${extractDir.path}/iamglass').readAsString(),
        'iamglass\n',
      );
      expect(File('${extractDir.path}/postlist.glass').existsSync(), isTrue);
      expect(
        await File('${extractDir.path}/postlist.glass').readAsString(),
        'postlist data',
      );

      await reader.close();
    });
  });
}
