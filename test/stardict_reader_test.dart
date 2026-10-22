import 'dart:io';

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
    expect(reader.words, ['apple', 'banana', 'Cherry']);

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
}
