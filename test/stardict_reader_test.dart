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
}
