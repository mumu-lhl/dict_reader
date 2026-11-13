import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

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

  group('Concurrent reads', () {
    test('parallel getEntry/readData calls return the right entries', () async {
      const count = 24;
      final builder = ZimFixtureBuilder()..addMetadata('Title', 'Race probe');
      final expectedBytes = <String, List<int>>{};
      for (var i = 0; i < count; i++) {
        // Long titles force the 2048-byte dirent fallback read, widening the
        // window in which concurrent reads used to interleave on one handle.
        final title = 'Article ${i}_${'T' * 300}';
        final body = 'body-$i-${'x' * (100 + i * 37)}';
        builder.addArticle('entry_$i', title, '<p>$body</p>');
        final data =
            List<int>.generate(200 + i * 53, (j) => (i * 31 + j) & 0xff);
        builder.addResource('res_$i.bin', data, 'application/octet-stream');
        expectedBytes['res_$i.bin'] = data;
      }
      final zimPath = await builder.write(
        dir,
        'race',
        compression: ZimCompression.zip,
        blobsPerCluster: 1,
      );
      final reader = ZimReader(zimPath);
      await reader.init();

      for (var round = 0; round < 2; round++) {
        final results = await Future.wait(
          List.generate(count, (i) => reader.readDataByPath('res_$i.bin')),
        );
        for (var i = 0; i < count; i++) {
          expect(results[i], expectedBytes['res_$i.bin']);
        }

        final entries = await Future.wait(
          List.generate(count, (i) => reader.getEntry(i)),
        );
        final sequential = <ZimEntry>[];
        for (var i = 0; i < count; i++) {
          sequential.add(await reader.getEntry(i));
        }
        for (var i = 0; i < count; i++) {
          expect(entries[i].path, sequential[i].path);
          expect(entries[i].title, sequential[i].title);
          expect(entries[i].mimeType, sequential[i].mimeType);
        }
      }
      await reader.close();
    });
  });

  group('New-namespace (C) archives', () {
    test('XHTML articles in C namespace are indexed as words', () async {
      final builder = ZimFixtureBuilder()
        ..addMetadata('Title', 'C-namespace probe')
        ..addArticle('Apple', 'Apple', '<p>apple</p>', namespace: 'C')
        ..addResource(
          'Apple.jpg',
          List<int>.generate(64, (i) => i),
          'image/jpeg',
          namespace: 'C',
        )
        ..addArticle('Banana', 'Banana', '<p>banana</p>', namespace: 'C')
        ..addResource(
          'xhtml-doc',
          utf8.encode('<html><body>xhtml</body></html>'),
          'application/xhtml+xml',
          namespace: 'C',
          title: 'Xhtml Article',
        );
      final zimPath = await builder.write(dir, 'c_namespace');
      final reader = ZimReader(zimPath);
      await reader.init();

      expect(reader.words, containsAll(['Apple', 'Banana', 'Xhtml Article']));
      expect(reader.words, isNot(contains('Apple.jpg')));
      expect(reader.wordCount, 3);

      final hits = await reader.lookup('Xhtml Article');
      expect(hits, hasLength(1));
      expect(hits.single.isHtml, isTrue);
      expect(reader.search('xht'), contains('Xhtml Article'));

      await reader.close();
    });
  });

  group('Redirect data reads', () {
    test('readData on a redirect entry returns the target content', () async {
      final zimPath = await basicBuilder().write(dir, 'redir_data');
      final reader = ZimReader(zimPath);
      await reader.init();

      final redir = await reader.getEntryByPath('apples');
      expect(redir, isNotNull);
      expect(redir!.isRedirect, isTrue);
      expect(await redir.readText(), contains('A red fruit.'));

      final redirOnly = await reader.lookup('apples', followRedirects: false);
      expect(await redirOnly.single.readText(), contains('A red fruit.'));

      final bytes = await (await redir.openRead())
          .fold(<int>[], (acc, chunk) => acc..addAll(chunk));
      expect(utf8.decode(bytes), contains('A red fruit.'));

      await reader.close();
    });
  });

  group('Format version', () {
    test('rejects pre-6.0 archives', () async {
      final zimPath = await basicBuilder().write(
        dir,
        'old_version',
        majorVersion: 5,
      );
      final reader = ZimReader(zimPath);
      expect(() => reader.init(), throwsA(isA<FormatException>()));
    });
  });

  group('Full-text search', () {
    test('matches an NFC query against NFD article text', () async {
      const nfdWord = 'cafe\u0301';
      const nfcWord = 'caf\u00E9';
      final builder = ZimFixtureBuilder()
        ..addArticle(
          nfdWord,
          nfdWord,
          '<html><body>un cafe\u0301 bien fort</body></html>',
        )
        ..addArticle(
          'plain',
          'plain',
          '<html><body>un cafe\u0301 ordinaire</body></html>',
        );
      final zimPath = await builder.write(dir, 'fulltext_nfc');
      final reader = ZimReader(zimPath);
      await reader.init();

      final results = await reader.searchFulltext(nfcWord);
      expect(
        results.map((r) => r.article.headword),
        containsAll([nfdWord, 'plain']),
      );
      await reader.close();
    });
  });

  group('Cluster cache (byte-capped LRU) and entryTitleAt', () {
    test(
        'byte-capped LRU retains more than 16 clusters and evicts oldest past the cap',
        () async {
      // Each article is its own zlib cluster decompressing to exactly
      // 1 MiB (8-byte offset table + blob), so 20 clusters fit the
      // 32 MiB cap while the old 16-cluster cap would have evicted the
      // first four.
      const blobSize = 1024 * 1024 - 8;
      final builder = ZimFixtureBuilder()..addMetadata('Title', 'Cache probe');
      for (var i = 0; i < 41; i++) {
        builder.addArticle('entry_$i', 'entry_$i', 'x' * blobSize);
      }
      final zimPath = await builder.write(
        dir,
        'cluster_cache',
        compression: ZimCompression.zip,
        blobsPerCluster: 1,
      );
      final reader = ZimReader(zimPath);
      await reader.init();

      for (var i = 0; i < 20; i++) {
        expect(await reader.readBlob(i, 0), hasLength(blobSize));
      }
      expect(reader.cachedClusterOrder, List.generate(20, (i) => i));
      expect(reader.cachedClusterBytes, 20 * 1024 * 1024);

      for (var i = 20; i < 40; i++) {
        expect(await reader.readBlob(i, 0), hasLength(blobSize));
      }
      // 40 MiB of clusters against a 32 MiB cap: the 8 oldest are gone.
      expect(reader.cachedClusterOrder, List.generate(32, (i) => i + 8));
      expect(reader.cachedClusterBytes, 32 * 1024 * 1024);

      // Re-reading a cached cluster is a hit: it moves to the
      // most-recent end, nothing is evicted.
      expect(await reader.readBlob(8, 0), hasLength(blobSize));
      expect(
          reader.cachedClusterOrder, [...List.generate(31, (i) => i + 9), 8]);
      expect(reader.cachedClusterBytes, 32 * 1024 * 1024);

      // Reading one more cluster evicts the then-oldest (9), not the
      // just-touched cluster 8.
      expect(await reader.readBlob(40, 0), hasLength(blobSize));
      expect(reader.cachedClusterOrder,
          [...List.generate(30, (i) => i + 10), 8, 40]);
      expect(reader.cachedClusterBytes, 32 * 1024 * 1024);

      await reader.close();
      expect(reader.cachedClusterOrder, isEmpty);
      expect(reader.cachedClusterBytes, 0);
    });

    test('a single cluster larger than the cache budget is not cached',
        () async {
      const blobSize = 33 * 1024 * 1024;
      final builder = ZimFixtureBuilder()
        ..addArticle('huge', 'huge', 'x' * blobSize);
      final zimPath = await builder.write(
        dir,
        'cluster_oversize',
        compression: ZimCompression.zip,
        blobsPerCluster: 1,
      );
      final reader = ZimReader(zimPath);
      await reader.init();

      expect(await reader.readBlob(0, 0), hasLength(blobSize));
      expect(reader.cachedClusterOrder, isEmpty);
      expect(reader.cachedClusterBytes, 0);

      await reader.close();
    });

    test(
        'readBlob returns identical bytes for uncompressed and compressed clusters',
        () async {
      final expected = <int, List<int>>{};
      ZimFixtureBuilder build() {
        final builder = ZimFixtureBuilder()..addMetadata('Title', 'Blob probe');
        for (var i = 0; i < 5; i++) {
          final data =
              List<int>.generate(100 + i * 37, (j) => (i * 31 + j) & 0xff);
          expected[i] = data;
          builder.addResource('res_$i.bin', data, 'application/octet-stream');
        }
        return builder;
      }

      // Uncompressed clusters: one blob per cluster, read straight off disk.
      final plainPath = await build().write(
        dir,
        'blob_plain',
        compression: ZimCompression.none,
        blobsPerCluster: 1,
      );
      final plain = ZimReader(plainPath);
      await plain.init();
      for (var i = 0; i < 5; i++) {
        expect(await plain.readBlob(i, 0), expected[i]);
      }
      // Whole uncompressed clusters are never materialized into the cache.
      expect(plain.cachedClusterOrder, isEmpty);
      await plain.close();

      // Same bytes from zlib-compressed clusters, which do go through
      // the decompression cache.
      final zipPath = await build().write(
        dir,
        'blob_zip',
        compression: ZimCompression.zip,
        blobsPerCluster: 1,
      );
      final zipped = ZimReader(zipPath);
      await zipped.init();
      for (var i = 0; i < 5; i++) {
        expect(await zipped.readBlob(i, 0), expected[i]);
      }
      expect(zipped.cachedClusterOrder, [0, 1, 2, 3, 4]);
      await zipped.close();
    });

    test('readBlob on extended uncompressed clusters returns exact bytes',
        () async {
      final builder = ZimFixtureBuilder()
        ..addMetadata('Title', 'Extended probe');
      final data = List<int>.generate(300, (j) => (j * 7 + 3) & 0xff);
      builder.addResource('res.bin', data, 'application/octet-stream');
      builder.addArticle('article', 'article', '<p>extended</p>');
      final zimPath = await builder.write(
        dir,
        'blob_extended',
        compression: ZimCompression.none,
        extendedClusters: true,
        blobsPerCluster: 1,
      );
      final reader = ZimReader(zimPath);
      await reader.init();

      expect(await reader.readBlob(0, 0), data);
      final article = await reader.lookup('article');
      expect(await article.single.readText(), contains('extended'));

      await reader.close();
    });

    test(
        'entryTitleAt matches getEntry titles and returns null for non-articles',
        () async {
      final zimPath = await basicBuilder().write(dir, 'entry_title_at');
      final reader = ZimReader(zimPath);
      await reader.init();

      final seenTitles = <String>[];
      for (var i = 0; i < reader.entryCount; i++) {
        final entry = await reader.getEntry(i);
        final title = reader.entryTitleAt(i);
        if (entry.namespace == 'A') {
          expect(title, entry.title, reason: 'entry $i (${entry.fullPath})');
          seenTitles.add(title!);
        } else {
          expect(title, isNull, reason: 'entry $i (${entry.fullPath})');
        }
      }
      // Non-null titles in entry order are exactly the word list.
      expect(seenTitles, reader.words);

      expect(() => reader.entryTitleAt(-1), throwsRangeError);
      expect(() => reader.entryTitleAt(reader.entryCount), throwsRangeError);

      await reader.close();
    });
  });

  group('Precomputed lowercase sort keys (P0-7)', () {
    test('prefix search order matches the old comparator, ASCII and CJK',
        () async {
      // Hand-computed code-unit order of normalizeKey(title).toLowerCase():
      // aardvark, apple, apricot, avocado, banana, zebra, éclair, école,
      // 上册, 上海, 北京, 北国
      // ('z' 0x7A < 'é' 0xE9 < CJK; 册 0x518C < 海 0x6D77; 京 0x4EAC < 国 0x56FD).
      final builder = ZimFixtureBuilder()
        ..addArticle('aardvark', 'aardvark', '<p>1</p>')
        ..addArticle('apple', 'Apple', '<p>2</p>')
        ..addArticle('apricot', 'apricot', '<p>3</p>')
        ..addArticle('avocado', 'Avocado', '<p>4</p>')
        ..addArticle('banana', 'banana', '<p>5</p>')
        ..addArticle('zebra', 'zebra', '<p>6</p>')
        ..addArticle('eclair', 'Éclair', '<p>7</p>')
        ..addArticle('ecole', 'École', '<p>8</p>')
        ..addArticle('shangce', '上册', '<p>9</p>')
        ..addArticle('shanghai', '上海', '<p>10</p>')
        ..addArticle('beijing', '北京', '<p>11</p>')
        ..addArticle('beiguo', '北国', '<p>12</p>');
      final zimPath = await builder.write(dir, 'sort_keys');
      final reader = ZimReader(zimPath);
      await reader.init();

      expect(reader.search('a'), ['aardvark', 'Apple', 'apricot', 'Avocado']);
      expect(reader.search('A'), ['aardvark', 'Apple', 'apricot', 'Avocado']);
      expect(reader.search('z'), ['zebra']);
      expect(reader.search('é'), ['Éclair', 'École']);
      expect(reader.search('É'), ['Éclair', 'École']);
      expect(reader.search('上'), ['上册', '上海']);
      expect(reader.search('北'), ['北京', '北国']);

      // The precomputed keys must be exactly the old comparator's keys:
      // re-derive the full order with the old formula and compare it
      // against the prefix groups above in cross-group order.
      final titles = [
        'aardvark',
        'Apple',
        'apricot',
        'Avocado',
        'banana',
        'zebra',
        'Éclair',
        'École',
        '上册',
        '上海',
        '北京',
        '北国',
      ];
      final oldOrder = List<String>.from(titles)
        ..sort(
          (a, b) => normalizeKey(a).toLowerCase().compareTo(
                normalizeKey(b).toLowerCase(),
              ),
        );
      expect(oldOrder, [
        'aardvark',
        'Apple',
        'apricot',
        'Avocado',
        'banana',
        'zebra',
        'Éclair',
        'École',
        '上册',
        '上海',
        '北京',
        '北国',
      ]);

      await reader.close();
    });

    test('NFC and NFD titles share one lowercase key, title order wins',
        () async {
      const nfcTitle = 'caf\u00E9';
      const nfdTitle = 'cafe\u0301';
      final builder = ZimFixtureBuilder()
        ..addArticle('cafe-nfc', nfcTitle, '<p>nfc body</p>')
        ..addArticle('cafe-nfd', nfdTitle, '<p>nfd body</p>');
      final zimPath = await builder.write(dir, 'sort_keys_nfc_nfd');
      final reader = ZimReader(zimPath);
      await reader.init();

      // Both titles normalize to the same lowercase key, so prefix search
      // lists both in article (path) order.
      expect(reader.search('caf'), [nfcTitle, nfdTitle]);

      // Both spellings resolve through the same binary-searched key to the
      // first title in article order. (The old putIfAbsent map returned the
      // NFD article for an NFD query; the sorted-array lookup is
      // deliberately canonical — one normalized word, one winner.)
      expect((await reader.lookup('CAF\u00C9')).single.title, nfcTitle);
      expect((await reader.lookup('CAFE\u0301')).single.title, nfcTitle);
      expect(reader.exist(nfcTitle), isTrue);
      expect(reader.exist(nfdTitle), isTrue);

      await reader.close();
    });
  });

  group('Canonical path index and lowercase binary search (P1-9)', () {
    test('bare and namespaced path lookups agree', () async {
      final zimPath = await basicBuilder().write(dir, 'canonical_path');
      final reader = ZimReader(zimPath);
      await reader.init();

      // Bare article paths resolve without a namespace argument.
      final appleBare = await reader.getEntryByPath('apple');
      expect(appleBare, isNotNull);
      expect(appleBare!.title, 'apple');
      final appleNs = await reader.getEntryByPath('A/apple');
      expect(appleNs, isNotNull);
      expect(appleNs!.index, appleBare.index);

      // Bare resource paths resolve to the I-namespace entry.
      final logoBare = await reader.getEntryByPath('img/logo.png');
      expect(logoBare, isNotNull);
      expect(logoBare!.mimeType, 'image/png');
      final logoNs = await reader.getEntryByPath('I/img/logo.png');
      expect(logoNs, isNotNull);
      expect(logoNs!.index, logoBare.index);

      // Redirect entries are reachable by bare path too.
      final redir = await reader.getEntryByPath('apples');
      expect(redir, isNotNull);
      expect(redir!.isRedirect, isTrue);

      // resolveIndex path fallback: full path direct, bare path derived.
      expect(reader.resolveIndex('A/apple'), appleBare.index);
      expect(reader.resolveIndex('I/img/logo.png'), logoBare.index);
      expect(reader.resolveIndex('img/logo.png'), logoBare.index);

      // Lowercase lookups go through the binary-searched sort keys.
      expect(reader.resolveIndex('BANANA'), isNotNull);
      expect(
        (await reader.lookup('BANANA')).single.title,
        'banana',
      );
      expect(
        (await reader.lookup('cherry')).single.title,
        'Cherry',
      );
      expect((await reader.lookup('CHERRY')).single.title, 'Cherry');

      // Missing paths and words still resolve to nothing.
      expect(await reader.getEntryByPath('no/such.png'), isNull);
      expect(reader.resolveIndex('no/such.png'), isNull);

      await reader.close();
    });

    test('Xapian paths are still found by prefix traversal', () async {
      final builder = ZimFixtureBuilder()
        ..addMetadata('Title', 'Xapian canonical')
        ..addArticle('solar_system', 'Solar System', '<p>Planets</p>')
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
      final zimPath = await builder.write(dir, 'xapian_canonical');
      final reader = ZimReader(zimPath);
      await reader.init();

      expect(reader.hasFulltextIndex, isTrue);
      expect(
        reader.fulltextIndexPaths,
        containsAll([
          'X/fulltext/xapian/iamglass',
          'X/fulltext/xapian/postlist.glass',
        ]),
      );

      final extractDir = Directory('${dir.path}/extracted_canonical');
      await reader.extractFulltextDatabase(extractDir);
      expect(
        await File('${extractDir.path}/iamglass').readAsString(),
        'iamglass\n',
      );
      expect(
        await File('${extractDir.path}/postlist.glass').readAsString(),
        'postlist data',
      );

      await reader.close();
    });

    test('cidx round-trip rebuilds the lowercase keys and namespaces',
        () async {
      final builder = ZimFixtureBuilder()
        ..addMetadata('Title', 'CIDX keys')
        ..addArticle('aardvark', 'Aardvark', '<p>1</p>')
        ..addArticle('apple', 'Apple', '<p>2</p>')
        ..addArticle('banana', 'Banana', '<p>3</p>')
        ..addArticle('beijing', '北京', '<p>4</p>')
        ..addArticle('cafe-nfc', 'caf\u00E9', '<p>5</p>')
        ..addResource(
          'img/logo.png',
          [0x89, 0x50, 0x4E, 0x47],
          'image/png',
        );
      final zimPath = await builder.write(dir, 'cidx_keys');
      final scanned = ZimReader(zimPath);
      await scanned.init();
      final cidxBytes = await scanned.exportCidx();

      final imported = ZimReader(zimPath);
      await imported.importCidx(cidxBytes);

      expect(imported.search('a'), scanned.search('a'));
      expect(imported.search('北'), scanned.search('北'));
      expect(imported.search('caf'), scanned.search('caf'));
      expect(
        (await imported.lookup('BANANA')).single.title,
        'Banana',
      );
      expect(
        (await imported.lookup('CAF\u00C9')).single.title,
        'caf\u00E9',
      );
      expect(imported.resolveIndex('img/logo.png'), isNotNull);
      expect(
        (await imported.getEntryByPath('img/logo.png'))!.mimeType,
        'image/png',
      );
      expect(
        (await imported.getEntryByPath('apple'))!.title,
        'Apple',
      );

      await scanned.close();
      await imported.close();
    });
  });

  group('Sliding-window dirent reads (P1-11)', () {
    test('tiny window still parses every dirent (isolate path)', () async {
      final builder = ZimFixtureBuilder()
        ..addMetadata('Title', 'Window probe')
        ..addArticle('apple', 'apple', '<p>red</p>')
        ..addArticle('banana', 'Banana', '<p>yellow</p>')
        ..addArticle('cherry', 'Cherry', '<p>round</p>')
        // Long title: straddles 64-byte windows and needs the 2048-byte
        // direct-read fallback (dirent is ~330 bytes).
        ..addArticle('long300', 'L${'o' * 299}', '<p>long</p>')
        // Very long title: longer than the 2048-byte fallback, so only the
        // bounded direct read (next dirent offset) can parse it.
        ..addArticle('long3000', 'M${'i' * 2999}', '<p>very long</p>')
        ..addResource('img/logo.png', [1, 2, 3, 4], 'image/png');
      final zimPath = await builder.write(dir, 'tiny_window');
      final reader = ZimReader(zimPath);
      await reader.init(direntWindowBytes: 64);

      expect(reader.wordCount, 5);
      expect(reader.words, containsAll(['apple', 'Banana', 'Cherry']));
      expect((await reader.lookup('apple')).single.title, 'apple');
      expect((await reader.lookup('BANANA')).single.title, 'Banana');
      expect(
        (await reader.lookup('L${'o' * 299}')).single.title,
        'L${'o' * 299}',
      );
      // The 3000-char title is verifiable through the index only:
      // _getEntry caps its dirent re-read at 2048 bytes (pre-existing,
      // out of scope), so lookup() of it throws exactly as before.
      // wordCount / words / search / resolveIndex prove the bounded
      // direct read in _parseZimIndex parsed it.
      expect(reader.words, contains('M${'i' * 2999}'));
      expect(reader.resolveIndex('M${'i' * 2999}'), isNotNull);
      expect(reader.search('m'), ['M${'i' * 2999}']);
      expect(reader.search('l'), ['L${'o' * 299}']);
      expect(
        (await reader.getEntryByPath('img/logo.png'))!.mimeType,
        'image/png',
      );
      expect(reader.title, 'Window probe');

      await reader.close();
    });

    test('tiny window without the isolate parses the same index', () async {
      final builder = ZimFixtureBuilder()
        ..addArticle('apple', 'apple', '<p>red</p>')
        ..addArticle('banana', 'Banana', '<p>yellow</p>')
        ..addArticle('long300', 'L${'o' * 299}', '<p>long</p>')
        ..addResource('img/logo.png', [1, 2, 3, 4], 'image/png');
      final zimPath = await builder.write(dir, 'tiny_window_no_isolate');
      final reader = ZimReader(zimPath);
      await reader.init(useIsolate: false, direntWindowBytes: 128);

      expect(reader.wordCount, 3);
      expect((await reader.lookup('BANANA')).single.title, 'Banana');
      expect(
        (await reader.lookup('L${'o' * 299}')).single.title,
        'L${'o' * 299}',
      );
      expect(reader.search('b'), ['Banana']);
      expect(
        (await reader.getEntryByPath('img/logo.png'))!.mimeType,
        'image/png',
      );

      await reader.close();
    });
  });

  group('importCidx in a worker isolate (P0-8)', () {
    // A large fixture: 8000 entries produce a ~370 KiB .cidx, above the
    // 256 KiB isolate threshold, so the default path takes the worker
    // isolate. Which path ran is not asserted by timing (flaky); instead
    // both paths are forced explicitly and must produce identical
    // results, and the default path must too.
    Future<(String, ZimReader, Uint8List)> buildLarge() async {
      final builder = ZimFixtureBuilder()
        ..addMetadata('Title', 'Large CIDX')
        ..addArticle('beijing-path', '北京', '<p>capital</p>')
        ..addArticle('cafe-path', 'caf\u00E9', '<p>coffee</p>')
        ..addResource('img/logo.png', [1, 2, 3, 4], 'image/png');
      for (var i = 0; i < 8000; i++) {
        builder.addArticle('article$i', 'Article$i', '<p>body $i</p>');
      }
      final zimPath = await builder.write(dir, 'large_cidx');
      final scanned = ZimReader(zimPath);
      await scanned.init();
      final cidxBytes = await scanned.exportCidx();
      return (zimPath, scanned, cidxBytes);
    }

    // Every lookup surface the app uses must agree with the full scan.
    Future<void> expectMatchesScanned(
      ZimReader imported,
      ZimReader scanned,
    ) async {
      expect(imported.wordCount, scanned.wordCount);
      expect(imported.words.length, scanned.words.length);
      expect(imported.search('article'), scanned.search('article'));
      expect(imported.search('北'), scanned.search('北'));
      expect(imported.search('caf'), scanned.search('caf'));
      expect(
        (await imported.lookup('ARTICLE1')).single.title,
        'Article1',
      );
      expect(
        (await imported.lookup('Article7999')).single.title,
        'Article7999',
      );
      expect(
        (await imported.lookup('北京')).single.title,
        '北京',
      );
      expect(
        (await imported.lookup('CAF\u00C9')).single.title,
        'caf\u00E9',
      );
      expect(
        imported.resolveIndex('Article4242'),
        scanned.resolveIndex('Article4242'),
      );
      expect(
        imported.resolveIndex('article4242'),
        scanned.resolveIndex('article4242'),
      );
      expect(
        imported.entryTitleAt(scanned.resolveIndex('Article4242')!),
        'Article4242',
      );
      expect(
        imported.entryTitleAt(scanned.resolveIndex('img/logo.png')!),
        isNull,
      );
      expect(
        (await imported.getEntryByPath('img/logo.png'))!.mimeType,
        'image/png',
      );
      expect(
        (await imported.getEntryByPath('beijing-path'))!.title,
        '北京',
      );
      expect(imported.title, scanned.title);
    }

    test(
        'large .cidx: isolate, inline and default imports match a full '
        'scan', () async {
      final (zimPath, scanned, cidxBytes) = await buildLarge();
      // Above the isolate threshold, so the default path must take the
      // worker isolate; the buffer size itself is the assertion.
      expect(cidxBytes.length, greaterThan(256 * 1024));

      final viaIsolate = ZimReader(zimPath);
      await viaIsolate.importCidx(cidxBytes, useIsolate: true);
      await expectMatchesScanned(viaIsolate, scanned);

      final inline = ZimReader(zimPath);
      await inline.importCidx(cidxBytes, useIsolate: false);
      await expectMatchesScanned(inline, scanned);

      final byDefault = ZimReader(zimPath);
      await byDefault.importCidx(cidxBytes);
      await expectMatchesScanned(byDefault, scanned);

      await scanned.close();
      await viaIsolate.close();
      await inline.close();
      await byDefault.close();
    });

    test('small .cidx imports on the default path and matches a full scan',
        () async {
      final builder = ZimFixtureBuilder()
        ..addMetadata('Title', 'Small CIDX')
        ..addArticle('aardvark', 'Aardvark', '<p>1</p>')
        ..addArticle('apple', 'Apple', '<p>2</p>')
        ..addArticle('beijing', '北京', '<p>3</p>')
        ..addResource('img/logo.png', [1, 2, 3, 4], 'image/png');
      final zimPath = await builder.write(dir, 'small_cidx');
      final scanned = ZimReader(zimPath);
      await scanned.init();
      final cidxBytes = await scanned.exportCidx();
      // Well below the isolate threshold, so the default path stays
      // inline.
      expect(cidxBytes.length, lessThan(256 * 1024));

      final imported = ZimReader(zimPath);
      await imported.importCidx(cidxBytes);

      expect(imported.search('a'), scanned.search('a'));
      expect(imported.search('北'), scanned.search('北'));
      expect(
        (await imported.lookup('APPLE')).single.title,
        'Apple',
      );
      expect(
        (await imported.lookup('北京')).single.title,
        '北京',
      );
      expect(
        imported.resolveIndex('aardvark'),
        scanned.resolveIndex('aardvark'),
      );
      expect(
        imported.entryTitleAt(scanned.resolveIndex('Aardvark')!),
        'Aardvark',
      );
      expect(
        (await imported.getEntryByPath('img/logo.png'))!.mimeType,
        'image/png',
      );

      await scanned.close();
      await imported.close();
    });

    test('stale .cidx throws FormatException on both paths', () async {
      final builder = ZimFixtureBuilder()
        ..addMetadata('Title', 'Stale CIDX')
        ..addArticle('apple', 'Apple', '<p>1</p>')
        ..addArticle('banana', 'Banana', '<p>2</p>');
      final zimPath = await builder.write(dir, 'stale_cidx');
      final scanned = ZimReader(zimPath);
      await scanned.init();
      final cidxBytes = await scanned.exportCidx();
      await scanned.close();

      // Moved mtime: the fingerprint no longer matches the file.
      await File(zimPath).setLastModified(
        DateTime.now().add(const Duration(hours: 1)),
      );
      final staleInline = ZimReader(zimPath);
      await expectLater(
        staleInline.importCidx(cidxBytes, useIsolate: false),
        throwsFormatException,
      );
      final staleIsolate = ZimReader(zimPath);
      await expectLater(
        staleIsolate.importCidx(cidxBytes, useIsolate: true),
        throwsFormatException,
      );
      // A failed import touches no reader state.
      expect(
        () => staleInline.resolveIndex('apple'),
        throwsStateError,
      );

      // A different file at the same path: size differs, so the
      // fingerprint mismatches too.
      final other = ZimFixtureBuilder()
        ..addArticle('cherry', 'Cherry', '<p>3</p>');
      await other.write(dir, 'stale_cidx');
      final swapped = ZimReader(zimPath);
      await expectLater(
        swapped.importCidx(cidxBytes),
        throwsFormatException,
      );
    });
  });
}
