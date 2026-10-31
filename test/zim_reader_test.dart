import 'dart:io';

import 'package:dict_reader/dict_reader.dart';
import 'package:test/test.dart';

import 'zim_fixture.dart';

void main() {
  late Directory dir;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('zim_test');
  });

  tearDown(() async {
    await dir.delete(recursive: true);
  });

  ZimFixtureBuilder basicBuilder() {
    return ZimFixtureBuilder()
      ..addMetadata('Title', 'Test Encyclopedia')
      ..addMetadata('Description', 'A test ZIM archive for unit tests')
      ..addMetadata('Language', 'eng')
      ..addMetadata('Creator', 'Unit Tester')
      ..addMetadata('Date', '2026-10-31')
      ..addArticle('apple', 'apple',
          '<html><body><h1>Apple</h1><p>A red fruit.</p></body></html>')
      ..addArticle('banana', 'banana',
          '<html><body><h1>Banana</h1><p>A yellow fruit.</p></body></html>')
      ..addArticle('Cherry', 'Cherry',
          '<html><body><h1>Cherry</h1><p>A small round stone fruit.</p></body></html>')
      ..addResource('img/logo.png',
          [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A], 'image/png')
      ..addRedirect('apples', 'apples', 'apple');
  }

  group('ZimReader basic operations', () {
    test('parses metadata and reads articles', () async {
      final zimPath = await basicBuilder().write(dir, 'basic');
      final reader = ZimReader(zimPath);
      await reader.init();

      expect(reader.title, 'Test Encyclopedia');
      expect(reader.description, 'A test ZIM archive for unit tests');
      expect(reader.language, 'eng');
      expect(reader.creator, 'Unit Tester');
      expect(reader.date, '2026-10-31');
      expect(reader.uuidHex.length, 32);

      // Total words should be the articles + redirect
      expect(reader.wordCount, 4);
      expect(
          reader.words, containsAll(['apple', 'banana', 'Cherry', 'apples']));

      // Exact lookup
      final apple = await reader.lookup('apple');
      expect(apple, hasLength(1));
      expect(apple.single.title, 'apple');
      expect(apple.single.mimeType, 'text/html');
      expect(apple.single.isHtml, isTrue);
      expect(await apple.single.readText(), contains('A red fruit.'));

      // Case-insensitive lookup
      final banana = await reader.lookup('BaNaNa');
      expect(banana, hasLength(1));
      expect(banana.single.title, 'banana');
      expect(await banana.single.readText(), contains('A yellow fruit.'));

      // Missing word
      final missing = await reader.lookup('nonexistent');
      expect(missing, isEmpty);
      expect(reader.exist('nonexistent'), isFalse);
      expect(reader.exist('apple'), isTrue);

      await reader.close();
    });

    test('initMetadata reads header and metadata before full init', () async {
      final zimPath = await basicBuilder().write(dir, 'metadata_early');
      final reader = ZimReader(zimPath);
      await reader.initMetadata();

      expect(reader.entryCount, greaterThan(0));
      expect(reader.clusterCount, greaterThan(0));
      expect(reader.mimeTypes, contains('text/html'));
      expect(reader.mimeTypes, contains('image/png'));
      expect(reader.hasTitleIndex, isTrue);

      await reader.close();
    });

    test('follows redirects by default and allows disabling it', () async {
      final zimPath = await basicBuilder().write(dir, 'redirect');
      final reader = ZimReader(zimPath);
      await reader.init();

      // Following redirect: 'apples' -> 'apple'
      final resolved = await reader.lookup('apples');
      expect(resolved, hasLength(1));
      expect(resolved.single.title, 'apple');
      expect(resolved.single.resolvedFrom, 'apples');
      expect(await resolved.single.readText(), contains('A red fruit.'));

      // Not following redirect: returns redirect entry itself
      final redirOnly = await reader.lookup('apples', followRedirects: false);
      expect(redirOnly, hasLength(1));
      expect(redirOnly.single.title, 'apples');
      expect(redirOnly.single.isRedirect, isTrue);

      await reader.close();
    });

    test('retrieves resources and handles relative paths', () async {
      final zimPath = await basicBuilder().write(dir, 'resource');
      final reader = ZimReader(zimPath);
      await reader.init();

      // Exact path
      final logo = await reader.getEntryByPath('img/logo.png');
      expect(logo, isNotNull);
      expect(logo!.isImage, isTrue);
      expect(logo.mimeType, 'image/png');
      final bytes = await logo.readData();
      expect(bytes, [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]);

      // Path with namespace prefix
      final logoNs = await reader.getEntryByPath('I/img/logo.png');
      expect(logoNs, isNotNull);

      // Relative path resolution (as in HTML articles)
      final logoRel = await reader.getEntryByPath('../I/img/logo.png');
      expect(logoRel, isNotNull);

      // readDataByPath convenience method
      final directBytes = await reader.readDataByPath('img/logo.png');
      expect(directBytes, [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]);

      final nonExistent = await reader.readDataByPath('missing.png');
      expect(nonExistent, isNull);

      await reader.close();
    });

    test('prefix search is case-insensitive, sorted and limited', () async {
      final builder = ZimFixtureBuilder()
        ..addArticle('aardvark', 'Aardvark', '...')
        ..addArticle('abacus', 'Abacus', '...')
        ..addArticle('abbey', 'Abbey', '...')
        ..addArticle('absolute', 'Absolute', '...')
        ..addArticle('banana', 'Banana', '...');
      final zimPath = await builder.write(dir, 'search');
      final reader = ZimReader(zimPath);
      await reader.init();

      final hits = reader.search('ab', limit: 2);
      expect(hits, ['Abacus', 'Abbey']);

      final allA = reader.search('a', limit: 10);
      expect(allA, ['Aardvark', 'Abacus', 'Abbey', 'Absolute']);

      final none = reader.search('xyz');
      expect(none, isEmpty);

      await reader.close();
    });

    test('supports mainPage entry', () async {
      final builder = basicBuilder()..mainPagePath = 'banana';
      final zimPath = await builder.write(dir, 'mainpage');
      final reader = ZimReader(zimPath);
      await reader.init();

      expect(reader.mainPage, isNot(0xffffffff));
      final mainEntry = await reader.getMainPageEntry();
      expect(mainEntry, isNotNull);
      expect(mainEntry!.title, 'banana');

      await reader.close();
    });
  });

  group('ZimReader compression codecs', () {
    test('reads from Zstandard (zstd) compressed clusters', () async {
      final zimPath = await basicBuilder().write(
        dir,
        'zstd_archive',
        compression: ZimCompression.zstd,
        blobsPerCluster: 2,
      );
      final reader = ZimReader(zimPath);
      await reader.init();

      expect(reader.title, 'Test Encyclopedia');

      final apple = await reader.lookup('apple');
      expect(apple, hasLength(1));
      expect(await apple.single.readText(), contains('A red fruit.'));

      final banana = await reader.lookup('banana');
      expect(banana, hasLength(1));
      expect(await banana.single.readText(), contains('A yellow fruit.'));

      final cherry = await reader.lookup('Cherry');
      expect(cherry, hasLength(1));
      expect(await cherry.single.readText(),
          contains('A small round stone fruit.'));

      await reader.close();
    });

    test('reads from LZMA2 (xz) compressed clusters', () async {
      final zimPath = await basicBuilder().write(
        dir,
        'lzma_archive',
        compression: ZimCompression.lzma,
        blobsPerCluster: 2,
      );
      final reader = ZimReader(zimPath);
      await reader.init();

      expect(reader.title, 'Test Encyclopedia');

      final apple = await reader.lookup('apple');
      expect(apple, hasLength(1));
      expect(await apple.single.readText(), contains('A red fruit.'));

      final cherry = await reader.lookup('Cherry');
      expect(cherry, hasLength(1));
      expect(await cherry.single.readText(),
          contains('A small round stone fruit.'));

      await reader.close();
    });

    test('reads from zlib compressed clusters', () async {
      final zimPath = await basicBuilder().write(
        dir,
        'zlib_archive',
        compression: ZimCompression.zip,
        blobsPerCluster: 2,
      );
      final reader = ZimReader(zimPath);
      await reader.init();

      expect(reader.title, 'Test Encyclopedia');

      final apple = await reader.lookup('apple');
      expect(apple, hasLength(1));
      expect(await apple.single.readText(), contains('A red fruit.'));

      await reader.close();
    });

    test('supports extended clusters (64-bit offsets)', () async {
      final zimPath = await basicBuilder().write(
        dir,
        'extended_archive',
        extendedClusters: true,
        compression: ZimCompression.none,
      );
      final reader = ZimReader(zimPath);
      await reader.init();

      final apple = await reader.lookup('apple');
      expect(apple, hasLength(1));
      expect(await apple.single.readText(), contains('A red fruit.'));

      await reader.close();
    });
  });

  group('Unicode NFC normalisation', () {
    test('finds an NFD headword from an NFC query and vice versa', () async {
      // e + combining acute: e\u0301 (NFD) vs é (NFC, \u00E9)
      const nfdWord = 'cafe\u0301';
      const nfcWord = 'caf\u00E9';

      final builder = ZimFixtureBuilder()
        ..addArticle(nfdWord, nfdWord, '<html><body>Coffee</body></html>')
        ..addArticle(
            'na\u00EFve', 'na\u00EFve', '<html><body>Naive</body></html>');

      final zimPath = await builder.write(dir, 'unicode_nfc');
      final reader = ZimReader(zimPath);
      await reader.init();

      // Look up using NFC query
      final nfcHit = await reader.lookup(nfcWord);
      expect(nfcHit, hasLength(1));
      expect(await nfcHit.single.readText(), contains('Coffee'));

      // Look up using NFD query for NFC headword
      const nfdNaive = 'nai\u0308ve';
      final nfdHit = await reader.lookup(nfdNaive);
      expect(nfdHit, hasLength(1));
      expect(await nfdHit.single.readText(), contains('Naive'));

      await reader.close();
    });
  });

  group('Error handling', () {
    test('throws FormatException on invalid magic number', () async {
      final badFile = File('${dir.path}/bad.zim');
      await badFile
          .writeAsBytes([0x00, 0x01, 0x02, 0x03, ...List.filled(76, 0)]);

      final reader = ZimReader(badFile.path);
      expect(() => reader.initMetadata(), throwsA(isA<FormatException>()));
    });

    test('close releases resources and prevents subsequent lookup', () async {
      final zimPath = await basicBuilder().write(dir, 'close_test');
      final reader = ZimReader(zimPath);
      await reader.init();
      await reader.close();

      expect(() => reader.lookup('apple'), throwsA(isA<StateError>()));
    });
  });
}
