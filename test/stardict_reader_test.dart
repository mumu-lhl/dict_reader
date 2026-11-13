import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dict_reader/dict_reader.dart';
import 'package:test/test.dart';

import 'stardict_fixture.dart';

void main() {
  late Directory dir;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('stardict_test');
  });

  tearDown(() async {
    await dir.delete(recursive: true);
  });

  StarDictFixtureBuilder basicBuilder() {
    return StarDictFixtureBuilder()
      ..add('apple', [
        ('m', 'a fruit with red skin'),
        ('t', "'æpl"),
      ])
      ..add('banana', [('m', 'a long yellow fruit')])
      ..add('Cherry', [('h', '<b>cherry</b> html content')]);
  }

  test('parses ifo metadata and plain-text entries without a sequence',
      () async {
    final base = await basicBuilder().write(dir, 'basic');
    final reader = StarDictReader(base);
    await reader.init();

    expect(reader.bookName, 'Test Dictionary');
    expect(reader.wordCount, 3);
    expect(reader.sameTypeSequence, isNull);
    // Words are reported in sorted index order, not insertion order.
    expect(reader.words, ['Cherry', 'apple', 'banana']);

    final entries = await reader.lookup('apple');
    expect(entries, hasLength(1));
    expect(entries.single.headword, 'apple');
    expect(entries.single.fields, hasLength(2));
    expect(entries.single.fields[0].type, 'm');
    expect(entries.single.fields[0].text, 'a fruit with red skin');
    expect(entries.single.fields[1].type, 't');
    expect(entries.single.fields[1].text, "'æpl");

    final html = await reader.lookup('Cherry');
    expect(html.single.fields.single.type, 'h');
    expect(html.single.fields.single.text, '<b>cherry</b> html content');
    await reader.close();
  });

  test('resolves case-insensitively and returns empty for missing words',
      () async {
    final base = await basicBuilder().write(dir, 'basic');
    final reader = StarDictReader(base);
    await reader.init();

    expect(reader.exist('APPLE'), isTrue);
    expect(reader.exist('missing'), isFalse);
    final entries = await reader.lookup('BANANA');
    expect(entries.single.headword, 'banana');
    expect(await reader.lookup('missing'), isEmpty);
    await reader.close();
  });

  test('decodes sametypesequence fields incl. binary uppercase types',
      () async {
    final builder = StarDictFixtureBuilder()
      ..add('sound', [
        ('m', 'a noise'),
        ('W', [1, 2, 3, 4, 5]),
      ]);
    final base = await builder.write(dir, 'seq', sameTypeSequence: 'mW');
    final reader = StarDictReader(base);
    await reader.init();

    expect(reader.sameTypeSequence, 'mW');
    final entries = await reader.lookup('sound');
    expect(entries.single.fields, hasLength(2));
    expect(entries.single.fields[0].text, 'a noise');
    expect(entries.single.fields[1].type, 'W');
    expect(entries.single.fields[1].text, isNull);
    expect(entries.single.fields[1].data, [1, 2, 3, 4, 5]);
    await reader.close();
  });

  test('follows synonyms from the .syn index', () async {
    final builder = basicBuilder()..addSynonym('fruit-fly', 1);
    final base = await builder.write(dir, 'syn');
    final reader = StarDictReader(base);
    await reader.init();

    expect(reader.exist('fruit-fly'), isTrue);
    final entries = await reader.lookup('fruit-fly');
    expect(entries.single.headword, 'banana');
    await reader.close();
  });

  test('reads entries from a dictzip .dict.dz across chunk boundaries',
      () async {
    final builder = StarDictFixtureBuilder()
      ..add('longword', [
        ('m', 'this definition is deliberately longer than one chunk'),
      ])
      ..add('short', [('m', 'tiny')]);
    final base = await builder.write(
      dir,
      'zipped',
      dictZip: true,
      dictZipChunkLength: 8,
    );
    final reader = StarDictReader(base);
    await reader.init();

    expect(reader.isDictZip, isTrue);
    final entries = await reader.lookup('longword');
    expect(
      entries.single.fields.single.text,
      'this definition is deliberately longer than one chunk',
    );
    final short = await reader.lookup('short');
    expect(short.single.fields.single.text, 'tiny');
    await reader.close();
  });

  group('DictZipReader large header and LRU cache', () {
    // P0-1 regression: a .dict.dz with >2037 chunks has an RA extra field
    // that pushes the gzip header past 4096 bytes; open() used to throw
    // RangeError while parsing the chunk table.
    test('opens a .dict.dz whose RA header exceeds 4096 bytes', () async {
      const chunkLength = 512;
      const chunkCount = 2266;
      final data = Uint8List(chunkLength * chunkCount);
      for (var i = 0; i < data.length; i++) {
        data[i] = i % 251;
      }
      final file = File('${dir.path}/big.dict.dz');
      await file.writeAsBytes(buildDictZip(data, chunkLength: chunkLength));
      final raf = await file.open();
      final reader = await DictZipReader.open(raf);
      expect(reader.totalSize, data.length);
      final back = await reader.read(0, data.length);
      expect(back, data);
      // A slice spanning the last chunks reads correctly too.
      final tail = await reader.read(data.length - 1000, 1000);
      expect(tail, Uint8List.sublistView(data, data.length - 1000));
      await raf.close();
    });

    test('throws FormatException when the dictzip chunk length is zero',
        () async {
      final dz = Uint8List.fromList(
        buildDictZip(Uint8List.fromList([1, 2, 3, 4]), chunkLength: 4),
      );
      // RA layout: 10-11 xlen, 12 'R', 13 'A', 14-15 slen, 16-17
      // version, 18-19 chlen, 20-21 chcnt. Zero the chlen field.
      dz[18] = 0;
      dz[19] = 0;
      final file = File('${dir.path}/zero-chlen.dict.dz');
      await file.writeAsBytes(dz);
      final raf = await file.open();
      await expectLater(DictZipReader.open(raf), throwsFormatException);
      await raf.close();
    });

    Future<DictZipReader> openDz(Uint8List data, int chunkLength) async {
      final file = File('${dir.path}/dz-$chunkLength-${data.length}.dict.dz');
      await file.writeAsBytes(buildDictZip(data, chunkLength: chunkLength));
      final raf = await file.open();
      addTearDown(raf.close);
      return DictZipReader.open(raf);
    }

    test('re-reading a chunk hits the cache and marks it most recent',
        () async {
      final data = Uint8List(8 * 16);
      for (var i = 0; i < data.length; i++) {
        data[i] = i;
      }
      final reader = await openDz(data, 16);

      expect(await reader.read(0, 16), Uint8List.sublistView(data, 0, 16));
      expect(reader.cachedChunkOrder, [0]);
      expect(reader.cachedChunkBytes, 16);
      await reader.read(16, 16);
      await reader.read(32, 16);
      expect(reader.cachedChunkOrder, [0, 1, 2]);
      // Re-reading chunk 0 hits the cache and moves it to the end.
      expect(await reader.read(0, 16), Uint8List.sublistView(data, 0, 16));
      expect(reader.cachedChunkOrder, [1, 2, 0]);
      // ... and again for chunk 1.
      await reader.read(16, 16);
      expect(reader.cachedChunkOrder, [2, 0, 1]);
      expect(reader.cachedChunkBytes, 3 * 16);
    });

    test('evicts the least-recently-used chunk once the byte cap is hit',
        () async {
      // 129 chunks of 32 KiB = ~4.2 MiB of decompressed data, over the
      // 4 MiB cap, so exactly the 128 newest chunks stay cached. (The
      // dictzip chunk length is a uint16, so chunks are capped at
      // 65535 bytes.)
      const chunkLength = 32 * 1024;
      const chunkCount = 129;
      final data = Uint8List(chunkLength * chunkCount);
      for (var i = 0; i < data.length; i++) {
        data[i] = i % 251;
      }
      final reader = await openDz(data, chunkLength);

      for (var i = 0; i < chunkCount; i++) {
        final back = await reader.read(i * chunkLength, chunkLength);
        expect(
          back,
          Uint8List.sublistView(
            data,
            i * chunkLength,
            (i + 1) * chunkLength,
          ),
        );
      }
      expect(reader.cachedChunkBytes, reader.maxChunkCacheBytes);
      expect(reader.cachedChunkBytes, 128 * chunkLength);
      expect(reader.cachedChunkOrder, [
        for (var i = chunkCount - 128; i < chunkCount; i++) i,
      ]);
      // The oldest surviving chunk is still a hit, and the hit moves it
      // to the most-recent end.
      final oldest = chunkCount - 128;
      await reader.read(oldest * chunkLength, chunkLength);
      expect(reader.cachedChunkOrder.first, oldest + 1);
      expect(reader.cachedChunkOrder.last, oldest);
      // An evicted chunk still reads correctly after a fresh inflate.
      final evicted = await reader.read(0, chunkLength);
      expect(evicted, Uint8List.sublistView(data, 0, chunkLength));
      expect(reader.cachedChunkOrder.last, 0);
      expect(reader.cachedChunkOrder.length, 128);
    });
  });

  group('concurrent lookups', () {
    // Regression tests for the shared-handle race: 40 entries with 60+
    // char definitions spanning several 16-byte dictzip chunks, looked up
    // 10 rounds x 40 concurrent lookup() calls on one reader. Before the
    // _readDict file lock, most concurrent lookups returned wrong text or
    // threw `FileSystemException: An async operation is currently pending`.
    List<String> concurrentWords() => [
          for (var i = 0; i < 40; i++) 'word${i.toString().padLeft(2, '0')}',
        ];

    String definitionFor(int i) =>
        'Definition number $i: ${'0123456789' * 7} end $i';

    StarDictFixtureBuilder concurrentBuilder() {
      final builder = StarDictFixtureBuilder();
      for (var i = 0; i < 40; i++) {
        builder.add(concurrentWords()[i], [('m', definitionFor(i))]);
      }
      return builder;
    }

    Future<void> checkConcurrentLookups(StarDictReader reader) async {
      final words = concurrentWords();
      // Sequential baseline: every entry correct in order.
      for (var i = 0; i < words.length; i++) {
        final entries = await reader.lookup(words[i]);
        expect(entries, hasLength(1));
        expect(entries.single.headword, words[i]);
        expect(entries.single.fields.single.text, definitionFor(i));
      }
      // Concurrent load: 10 rounds x 40 concurrent lookups, 400/400 correct.
      var correct = 0;
      for (var round = 0; round < 10; round++) {
        final results = await Future.wait(
          [for (final word in words) reader.lookup(word)],
        );
        for (var i = 0; i < words.length; i++) {
          expect(results[i], hasLength(1));
          expect(results[i].single.headword, words[i]);
          expect(results[i].single.fields.single.text, definitionFor(i));
          correct++;
        }
      }
      expect(correct, 400);
    }

    test('returns correct entries for concurrent lookups of a .dict.dz',
        () async {
      final base = await concurrentBuilder().write(
        dir,
        'concurrent-dz',
        dictZip: true,
        dictZipChunkLength: 16,
      );
      final reader = StarDictReader(base);
      await reader.init();
      expect(reader.isDictZip, isTrue);
      await checkConcurrentLookups(reader);
      await reader.close();
    });

    test('returns correct entries for concurrent lookups of a plain .dict',
        () async {
      final base = await concurrentBuilder().write(dir, 'concurrent-plain');
      final reader = StarDictReader(base);
      await reader.init();
      expect(reader.isDictZip, isFalse);
      await checkConcurrentLookups(reader);
      await reader.close();
    });
  });

  test('supports 64-bit index offsets', () async {
    final base = await basicBuilder().write(dir, 'wide', offsetBits: 64);
    final reader = StarDictReader(base);
    await reader.init();

    expect(reader.version, '3.0.0');
    final entries = await reader.lookup('banana');
    expect(entries.single.fields.single.text, 'a long yellow fruit');
    await reader.close();
  });

  test('prefix search is case-insensitive, sorted and limited', () async {
    final builder = StarDictFixtureBuilder()
      ..add('apply', [('m', 'x')])
      ..add('apple', [('m', 'x')])
      ..add('Apricot', [('m', 'x')])
      ..add('berry', [('m', 'x')]);
    final base = await builder.write(dir, 'search');
    final reader = StarDictReader(base);
    await reader.init();

    expect(reader.search('ap'), ['apple', 'apply', 'Apricot']);
    expect(reader.search('AP', limit: 2), ['apple', 'apply']);
    expect(reader.search('zzz'), isEmpty);
    await reader.close();
  });

  test('throws a clear error when companion files are missing', () async {
    final reader = StarDictReader('${dir.path}/nonexistent');
    await expectLater(reader.init(), throwsStateError);
  });

  test('tolerates a malformed UTF-8 word in the index', () async {
    // Hand-build a dictionary whose .idx holds one word with an invalid
    // UTF-8 byte (0xFF) next to a valid word.
    final base = '${dir.path}/malformed';
    final dictBytes = BytesBuilder()
      ..addByte(0x6d) // 'm'
      ..add(utf8.encode('good entry'))
      ..addByte(0)
      ..addByte(0x6d)
      ..add(utf8.encode('bad entry'))
      ..addByte(0);
    final dictData = dictBytes.takeBytes();
    final firstEntrySize = 1 + 'good entry'.length + 1;

    final idx = BytesBuilder();
    void addIdx(List<int> wordBytes, int offset, int size) {
      idx.add(wordBytes);
      idx.addByte(0);
      idx.add(
        (ByteData(4)..setUint32(0, offset, Endian.big)).buffer.asUint8List(),
      );
      idx.add(
        (ByteData(4)..setUint32(0, size, Endian.big)).buffer.asUint8List(),
      );
    }

    addIdx(utf8.encode('good'), 0, firstEntrySize);
    addIdx(
        [0x62, 0xFF, 0x64], firstEntrySize, dictData.length - firstEntrySize);

    await File('$base.dict').writeAsBytes(dictData);
    await File('$base.idx').writeAsBytes(idx.takeBytes());
    await File('$base.ifo').writeAsString(
      "StarDict's dict ifo file\n"
      'version=2.4.2\n'
      'bookname=Malformed\n'
      'wordcount=2\n',
    );

    final reader = StarDictReader(base);
    await reader.init();
    expect(reader.words, hasLength(2));
    final entries = await reader.lookup('good');
    expect(entries.single.fields.single.text, 'good entry');
    await reader.close();
  });

  test('search does not repeat words that have several entries', () async {
    final builder = StarDictFixtureBuilder()
      ..add('echo', [('m', 'first')])
      ..add('echo', [('m', 'second')])
      ..add('eclipse', [('m', 'x')]);
    final base = await builder.write(dir, 'dupes');
    final reader = StarDictReader(base);
    await reader.init();

    expect(await reader.lookup('echo'), hasLength(2));
    expect(reader.search('ec'), ['echo', 'eclipse']);
    await reader.close();
  });

  group('Unicode NFC lookup', () {
    test('finds a decomposed headword from an NFC query, keeping its spelling',
        () async {
      final builder = StarDictFixtureBuilder()
        ..add('ingle\u0301s', [('m', 'spanish')])
        ..add('plain', [('m', 'P')]);
      final base = await builder.write(dir, 'nfc');
      final reader = StarDictReader(base);
      await reader.init();

      expect(reader.exist('ingl\u00E9s'), isTrue);
      expect(reader.exist('ingle\u0301s'), isTrue);
      final entries = await reader.lookup('ingl\u00E9s');
      expect(entries.single.headword, 'ingle\u0301s');
      expect(entries.single.fields.single.text, 'spanish');
      expect(reader.search('ingl'), ['ingle\u0301s']);
      await reader.close();
    });

    test('finds a composed headword from a decomposed query', () async {
      final builder = StarDictFixtureBuilder()
        ..add('ingl\u00E9s', [('m', 'spanish')]);
      final base = await builder.write(dir, 'nfc-reverse');
      final reader = StarDictReader(base);
      await reader.init();

      // The headword is stored composed, so the byte search has to run
      // against the normalised query: the decomposed spelling alone never
      // matches the stored bytes.
      expect(reader.exist('ingle\u0301s'), isTrue);
      final entries = await reader.lookup('ingle\u0301s');
      expect(entries.single.headword, 'ingl\u00E9s');
      expect(entries.single.fields.single.text, 'spanish');
      await reader.close();
    });

    test('an exact spelling wins over a twin that normalises alike', () async {
      final builder = StarDictFixtureBuilder()
        ..add('ingl\u00E9s', [('m', 'composed')])
        ..add('ingle\u0301s', [('m', 'decomposed')]);
      final base = await builder.write(dir, 'nfc-twins');
      final reader = StarDictReader(base);
      await reader.init();

      final composed = reader.resolveIndex('ingl\u00E9s');
      expect(reader.wordAt(composed!), 'ingl\u00E9s');
      final decomposed = reader.resolveIndex('ingle\u0301s');
      expect(reader.wordAt(decomposed!), 'ingle\u0301s');

      final entries = await reader.lookup('ingl\u00E9s');
      expect(entries, hasLength(1));
      expect(entries.single.fields.single.text, 'composed');
      await reader.close();
    });

    test('resolves a decomposed synonym from either spelling', () async {
      final builder = StarDictFixtureBuilder()
        ..add('banana', [('m', 'a long yellow fruit')])
        ..addSynonym('pla\u0301tano', 0);
      final base = await builder.write(dir, 'nfc-synonym');
      final reader = StarDictReader(base);
      await reader.init();

      expect(reader.exist('pl\u00E1tano'), isTrue);
      expect(reader.exist('pla\u0301tano'), isTrue);
      expect(
        (await reader.lookup('pl\u00E1tano')).single.headword,
        'banana',
      );
      expect(
        (await reader.lookup('pla\u0301tano')).single.headword,
        'banana',
      );
      await reader.close();
    });

    test('prefix search matches a decomposed query against either spelling',
        () async {
      final builder = StarDictFixtureBuilder()
        ..add('ingle\u0301s', [('m', 'spanish')])
        ..add('plain', [('m', 'P')]);
      final base = await builder.write(dir, 'nfc-search');
      final reader = StarDictReader(base);
      await reader.init();

      expect(reader.search('ingl\u00E9'), ['ingle\u0301s']);
      expect(reader.search('ingle\u0301'), ['ingle\u0301s']);
      await reader.close();
    });
  });

  group('gzip-compressed index files', () {
    // The format allows `.idx.gz` / `.syn.gz` in place of the plain
    // files; dictionaries are commonly distributed that way.

    test('opens a dictionary whose index is only available as .idx.gz',
        () async {
      final base = await basicBuilder().write(dir, 'idx-gz');
      final idxFile = File('$base.idx');
      await File('$base.idx.gz').writeAsBytes(
        GZipCodec().encode(await idxFile.readAsBytes()),
      );
      await idxFile.delete();

      final reader = StarDictReader(base);
      await reader.init();
      expect(reader.words, ['Cherry', 'apple', 'banana']);
      final entries = await reader.lookup('apple');
      expect(entries.single.fields.first.text, 'a fruit with red skin');
      await reader.close();
    });

    test('resolves synonyms from a .syn.gz file', () async {
      final builder = basicBuilder()..addSynonym('fruit-fly', 1);
      final base = await builder.write(dir, 'syn-gz');
      final synFile = File('$base.syn');
      await File('$base.syn.gz').writeAsBytes(
        GZipCodec().encode(await synFile.readAsBytes()),
      );
      await synFile.delete();

      final reader = StarDictReader(base);
      await reader.init();
      expect(reader.exist('fruit-fly'), isTrue);
      final entries = await reader.lookup('fruit-fly');
      expect(entries.single.headword, 'banana');
      await reader.close();
    });

    test('prefers the plain index when both forms exist', () async {
      final base = await basicBuilder().write(dir, 'idx-both');
      await File('$base.idx.gz').writeAsBytes(
        GZipCodec().encode(utf8.encode('garbage')),
      );

      final reader = StarDictReader(base);
      await reader.init();
      expect(reader.words, ['Cherry', 'apple', 'banana']);
      await reader.close();
    });
  });

  group('dictzipped synonym index', () {
    // PyGlossary's `dictzip_syn` option writes the `.syn` index through
    // dictzip, so a converted dictionary carries `.syn.dz` and no plain file.

    test('resolves synonyms from a .syn.dz file', () async {
      final builder = basicBuilder()..addSynonym('fruit-fly', 1);
      final base = await builder.write(dir, 'syn-dz');
      final synFile = File('$base.syn');
      final syn = await synFile.readAsBytes();
      // A synonym index is small, so dictzip stores it as a single chunk —
      // the shape PyGlossary's `dictzip_syn` output takes.
      await File('$base.syn.dz').writeAsBytes(
        buildDictZip(syn, chunkLength: syn.length),
      );
      await synFile.delete();

      final reader = StarDictReader(base);
      await reader.init();
      expect(reader.exist('fruit-fly'), isTrue);
      final entries = await reader.lookup('fruit-fly');
      expect(entries.single.headword, 'banana');
      await reader.close();
    });

    test('prefers the plain synonym index when both forms exist', () async {
      final builder = basicBuilder()..addSynonym('fruit-fly', 1);
      final base = await builder.write(dir, 'syn-both');
      await File('$base.syn.dz').writeAsBytes(
        buildDictZip(utf8.encode('garbage'), chunkLength: 16),
      );

      final reader = StarDictReader(base);
      await reader.init();
      expect(reader.exist('fruit-fly'), isTrue);
      await reader.close();
    });
  });

  group('StarDict .cidx export/import', () {
    StarDictFixtureBuilder cidxBuilder() {
      return StarDictFixtureBuilder()
        ..add('apple', [('m', 'a fruit with red skin')])
        ..add('banana', [('m', 'a long yellow fruit')])
        ..add('Cherry', [('h', '<b>cherry</b> html content')])
        // Synonyms in byte order: the `.syn` file is binary-searched
        // in place, so it must be sorted like a real dictionary's.
        ..addSynonym('FRUIT', 1)
        ..addSynonym('fruit-fly', 1);
    }

    /// The user-visible behaviour a reader must show, whether it was
    /// fully parsed or restored from a `.cidx`.
    Future<void> checkCidxDictionary(StarDictReader reader) async {
      expect(reader.words, ['Cherry', 'apple', 'banana']);
      expect(reader.bookName, 'Test Dictionary');
      expect(reader.search('ap'), ['apple']);
      expect(reader.search('fr'), ['FRUIT', 'fruit-fly']);
      expect(reader.search('FRU'), ['FRUIT', 'fruit-fly']);
      expect(reader.resolveIndex('APPLE'), reader.resolveIndex('apple'));
      expect(reader.exist('fruit-fly'), isTrue);
      expect(reader.exist('FRUIT'), isTrue);
      final apple = await reader.lookup('apple');
      expect(apple.single.fields.first.text, 'a fruit with red skin');
      final fly = await reader.lookup('fruit-fly');
      expect(fly.single.headword, 'banana');
      final fruit = await reader.lookup('FRUIT');
      expect(fruit.single.headword, 'banana');
      final cherry = await reader.lookup('Cherry');
      expect(cherry.single.fields.single.type, 'h');
    }

    test('round-trips a dictionary with synonyms through export/import',
        () async {
      final base = await cidxBuilder().write(dir, 'cidx');
      final reader = StarDictReader(base);
      await reader.init();
      await checkCidxDictionary(reader);
      final bytes = await reader.exportCidx();
      await reader.close();

      final restored = StarDictReader(base);
      await restored.importCidx(bytes);
      await checkCidxDictionary(restored);
      await restored.close();
    });

    test('round-trips a dictzip dictionary through export/import', () async {
      final base = await cidxBuilder().write(
        dir,
        'cidx-dz',
        dictZip: true,
      );
      final reader = StarDictReader(base);
      await reader.init();
      expect(reader.isDictZip, isTrue);
      final bytes = await reader.exportCidx();
      await reader.close();

      final restored = StarDictReader(base);
      await restored.importCidx(bytes);
      expect(restored.isDictZip, isTrue);
      await checkCidxDictionary(restored);
      await restored.close();
    });

    test('round-trips a dictionary with 64-bit index offsets', () async {
      final base = await cidxBuilder().write(
        dir,
        'cidx-wide',
        offsetBits: 64,
      );
      final reader = StarDictReader(base);
      await reader.init();
      final bytes = await reader.exportCidx();
      await reader.close();

      final restored = StarDictReader(base);
      await restored.importCidx(bytes);
      await checkCidxDictionary(restored);
      await restored.close();
    });

    test('round-trips a dictionary with decomposed headwords and synonyms',
        () async {
      final builder = StarDictFixtureBuilder()
        ..add('banana', [('m', 'a long yellow fruit')])
        ..add('ingle\u0301s', [('m', 'spanish')])
        ..addSynonym('pla\u0301tano', 0);
      final base = await builder.write(dir, 'cidx-nfc');
      final reader = StarDictReader(base);
      await reader.init();
      final bytes = await reader.exportCidx();
      await reader.close();

      final restored = StarDictReader(base);
      await restored.importCidx(bytes);
      expect(restored.exist('ingl\u00E9s'), isTrue);
      expect(
        (await restored.lookup('ingl\u00E9s')).single.headword,
        'ingle\u0301s',
      );
      expect(restored.search('ingl'), ['ingle\u0301s']);
      expect(restored.exist('pl\u00E1tano'), isTrue);
      expect(
        (await restored.lookup('pl\u00E1tano')).single.headword,
        'banana',
      );
      await restored.close();
    });

    test('exportCidx requires a completed init', () async {
      final base = await cidxBuilder().write(dir, 'cidx-noinit');
      final reader = StarDictReader(base);
      await expectLater(reader.exportCidx(), throwsStateError);
      await reader.close();
    });

    test('rejects a .cidx exported from a different dictionary', () async {
      final baseA = await cidxBuilder().write(dir, 'cidx-a');
      final readerA = StarDictReader(baseA);
      await readerA.init();
      final bytes = await readerA.exportCidx();
      await readerA.close();

      final baseB = await basicBuilder().write(dir, 'cidx-b');
      final readerB = StarDictReader(baseB);
      await expectLater(readerB.importCidx(bytes), throwsFormatException);
      await readerB.close();
    });

    test('rejects a .cidx when the index file mtime changed', () async {
      final base = await cidxBuilder().write(dir, 'cidx-mtime');
      final reader = StarDictReader(base);
      await reader.init();
      final bytes = await reader.exportCidx();
      await reader.close();

      final idxFile = File('$base.idx');
      final stat = await idxFile.stat();
      await idxFile.setLastModified(
        stat.modified.add(const Duration(seconds: 1)),
      );

      final restored = StarDictReader(base);
      await expectLater(restored.importCidx(bytes), throwsFormatException);
      await restored.close();
    });

    test('rejects a .cidx when the synonym index is gone', () async {
      final base = await cidxBuilder().write(dir, 'cidx-syn-gone');
      final reader = StarDictReader(base);
      await reader.init();
      final bytes = await reader.exportCidx();
      await reader.close();

      await File('$base.syn').delete();

      final restored = StarDictReader(base);
      await expectLater(restored.importCidx(bytes), throwsFormatException);
      await restored.close();
    });

    test('rejects truncated or corrupt .cidx bytes', () async {
      final base = await cidxBuilder().write(dir, 'cidx-corrupt');
      final reader = StarDictReader(base);
      await reader.init();
      final bytes = await reader.exportCidx();
      await reader.close();

      final restored = StarDictReader(base);
      await expectLater(
        restored.importCidx(bytes.sublist(0, bytes.length ~/ 2)),
        throwsFormatException,
      );
      await expectLater(
        restored.importCidx(
          Uint8List.fromList(bytes)..[0] = 'X'.codeUnitAt(0),
        ),
        throwsFormatException,
      );
      await expectLater(
        restored.importCidx(Uint8List.fromList(bytes)..[4] = 99),
        throwsFormatException,
      );
      await expectLater(
        restored.importCidx(Uint8List.fromList([...bytes, 0])),
        throwsFormatException,
      );
      await expectLater(
        restored.importCidx(Uint8List.fromList([1, 2, 3])),
        throwsFormatException,
      );
      await restored.close();
    });
  });

  group('parse shape: sortedness and word kinds', () {
    test('sorts an unsorted .idx, keeping duplicates in file order', () async {
      final builder = StarDictFixtureBuilder()
        ..add('banana', [('m', 'yellow')])
        ..add('apple', [('m', 'red')])
        ..add('Cherry', [('m', 'dark red')])
        ..add('apple', [('m', 'green')]);
      final base = await builder.write(dir, 'unsorted');
      final reader = StarDictReader(base);
      await reader.init();

      expect(reader.words, ['Cherry', 'apple', 'apple', 'banana']);
      expect(reader.search('a'), ['apple']);
      final apples = await reader.lookup('apple');
      expect(apples, hasLength(2));
      expect(apples[0].fields.single.text, 'red');
      expect(apples[1].fields.single.text, 'green');
      await reader.close();
    });

    test('handles CJK headwords alongside ASCII ones', () async {
      final builder = StarDictFixtureBuilder()
        ..add('你好', [('m', 'hello')])
        ..add('世界', [('m', 'world')])
        ..add('你', [('m', 'you')])
        ..add('apple', [('m', 'fruit')])
        ..add('Apple', [('m', 'fruit capital')]);
      final base = await builder.write(dir, 'cjk');
      final reader = StarDictReader(base);
      await reader.init();

      // Byte order: ASCII first, then CJK by UTF-8 bytes.
      expect(reader.words, ['Apple', 'apple', '世界', '你', '你好']);
      expect(reader.search('你'), ['你', '你好']);
      expect(reader.search('app'), ['apple', 'Apple']);
      expect(
        (await reader.lookup('世界')).single.fields.single.text,
        'world',
      );
      final bytes = await reader.exportCidx();
      await reader.close();

      final restored = StarDictReader(base);
      await restored.importCidx(bytes);
      expect(restored.words, ['Apple', 'apple', '世界', '你', '你好']);
      expect(restored.search('你'), ['你', '你好']);
      expect(
        (await restored.lookup('你好')).single.fields.single.text,
        'hello',
      );
      await restored.close();
    });
  });
}
