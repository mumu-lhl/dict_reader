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

List<int> _block(List<int> payload, {int compressionMethod = 0}) {
  final builder = BytesBuilder();
  _writeUint32LE(builder, compressionMethod);
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
  int recordCompressionMethod = 0,
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
  final recordBlocks = (recordBlockPayloads ?? [recordPayload])
      .map((payload) =>
          _block(payload, compressionMethod: recordCompressionMethod))
      .toList();
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

  test('names the compression method it cannot decode', () async {
    final directory =
        await Directory.systemTemp.createTemp('dict_reader_lzo_test_');
    addTearDown(() => directory.delete(recursive: true));
    // Method 1 is LZO. The payload stays raw on purpose: the reader has to
    // name the method before it gets as far as decoding anything.
    final file = await _createFixture(directory, recordCompressionMethod: 1);

    final reader = DictReader(file.path);
    await reader.initDict();
    addTearDown(reader.close);

    final offset = await reader.locate('alpha');
    expect(offset, isNotNull);
    await expectLater(
      reader.readOneMdx(offset!),
      throwsA(
        isA<UnsupportedCompressionException>().having(
          (error) => error.method,
          'method',
          1,
        ),
      ),
    );
  });

  test('uses a sorted index for search and duplicate keys', () async {
    final directory =
        await Directory.systemTemp.createTemp('dict_reader_search_test_');
    addTearDown(() => directory.delete(recursive: true));
    final file = await _createFixture(
      directory,
      entries: [
        ('beta', 'first'),
        ('alpha', 'A'),
        ('beta', 'second'),
        ('betamax', 'C'),
      ],
    );

    final reader = DictReader(file.path);
    await reader.initDict();
    addTearDown(reader.close);

    expect(reader.search('be'), ['beta', 'beta', 'betamax']);
    expect(reader.search('be', limit: 2), ['beta', 'beta']);
    expect(reader.exist('beta'), isTrue);
    expect(reader.exist('missing'), isFalse);

    final offsets = await reader.locateAll('beta');
    expect(
        await Future.wait(offsets.map(reader.readOneMdx)), ['first', 'second']);
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

  test('does not let a nested read disturb record iteration', () async {
    final directory =
        await Directory.systemTemp.createTemp('dict_reader_concurrency_test_');
    addTearDown(() => directory.delete(recursive: true));
    final file = await _createFixture(
      directory,
      entries: [('alpha', 'A'), (r'$beta', 'B'), ('gamma', 'C')],
      recordBlockPayloads: [
        utf8.encode('A'),
        utf8.encode('B'),
        utf8.encode('C'),
      ],
    );

    final reader = DictReader(file.path);
    await reader.initDict();
    addTearDown(reader.close);

    final keys = <String>[];
    await for (final offset in reader.readWithOffset()) {
      keys.add(offset.keyText);
      if (offset.keyText == 'alpha') {
        final gamma = await reader.locate('gamma');
        expect(await reader.readOneMdx(gamma!), 'C');
      }
    }

    expect(keys, ['alpha', r'$beta', 'gamma']);
  });

  test('imports a cidx index into a fresh reader', () async {
    final directory =
        await Directory.systemTemp.createTemp('dict_reader_cidx_test_');
    addTearDown(() => directory.delete(recursive: true));
    final file = await _createFixture(directory, entries: const [
      ('alpha', 'A'),
      (r'$beta', 'B'),
      ('gamma', 'C'),
    ]);

    final source = DictReader(file.path);
    await source.initDict();
    final cidx = await source.exportCidx();
    await source.close();

    final reader = DictReader(file.path);
    await reader.importCidx(cidx);
    addTearDown(reader.close);

    final offset = await reader.locate('alpha');
    expect(offset, isNotNull);
    expect(await reader.readOneMdx(offset!), 'A');
    expect(reader.exist('gamma'), isTrue);
    expect(reader.exist('missing'), isFalse);
    expect(reader.search('a'), ['alpha']);
    expect(reader.search(''), [r'$beta', 'alpha', 'gamma']);
  });

  test('cidx round-trip matches the scanned reader', () async {
    final directory =
        await Directory.systemTemp.createTemp('dict_reader_cidx_parity_');
    addTearDown(() => directory.delete(recursive: true));
    // Duplicate headwords, unsorted file order, and a non-ASCII key.
    final file = await _createFixture(directory, entries: const [
      ('banana', 'B1'),
      ('Apple', 'A1'),
      ('banana', 'B2'),
      ('äpfel', 'Ä'),
      ('apple', 'a2'),
    ]);

    final scanned = DictReader(file.path);
    await scanned.initDict();
    addTearDown(scanned.close);
    final cidx = await scanned.exportCidx();

    final imported = DictReader(file.path);
    await imported.importCidx(cidx);
    addTearDown(imported.close);

    for (final word in ['banana', 'Apple', 'apple', 'äpfel', 'missing']) {
      expect(imported.exist(word), scanned.exist(word), reason: word);
      final scannedOffsets = await scanned.locateAll(word);
      final importedOffsets = await imported.locateAll(word);
      expect(importedOffsets.length, scannedOffsets.length, reason: word);
      for (var i = 0; i < scannedOffsets.length; i++) {
        expect(
          await imported.readOneMdx(importedOffsets[i]),
          await scanned.readOneMdx(scannedOffsets[i]),
          reason: '$word#$i',
        );
      }
    }
    for (final prefix in ['a', 'ap', 'b', 'ban', 'ä', '']) {
      expect(
        imported.search(prefix).toSet(),
        scanned.search(prefix).toSet(),
        reason: 'prefix $prefix',
      );
    }
    // The file-order streaming API still works after a cidx import,
    // via the lazily built file-order key list.
    final streamed = <(String, String)>[];
    await for (final record in imported.readWithMdxData()) {
      streamed.add((record.keyText, record.data));
    }
    expect(streamed, [
      ('banana', 'B1'),
      ('Apple', 'A1'),
      ('banana', 'B2'),
      ('äpfel', 'Ä'),
      ('apple', 'a2'),
    ]);
  });

  test('cidx import tolerates a malformed headword', () async {
    final directory =
        await Directory.systemTemp.createTemp('dict_reader_cidx_badkey_');
    addTearDown(() => directory.delete(recursive: true));
    // A raw 0xFF byte is not valid UTF-8: the tolerant decoder drops it,
    // and the cleaned key is what the index stores.
    final file = await _createFixture(
      directory,
      entries: const [('good', 'G'), ('bad', 'B')],
      keyBytesOverride: [
        utf8.encode('good'),
        [0x62, 0x61, 0xff, 0x64],
      ],
    );

    final scanned = DictReader(file.path);
    await scanned.initDict();
    addTearDown(scanned.close);
    final cidx = await scanned.exportCidx();

    final imported = DictReader(file.path);
    await imported.importCidx(cidx);
    addTearDown(imported.close);

    expect(imported.exist('good'), isTrue);
    expect(imported.exist('bad'), isTrue);
    final offset = await imported.locate('bad');
    expect(offset, isNotNull);
    expect(await imported.readOneMdx(offset!), 'B');
  });

  test('rejects a cidx with an unsupported version', () async {
    final directory =
        await Directory.systemTemp.createTemp('dict_reader_cidx_version_');
    addTearDown(() => directory.delete(recursive: true));
    final file = await _createFixture(directory);

    final source = DictReader(file.path);
    await source.initDict();
    final cidx = await source.exportCidx();
    await source.close();
    // Version field: bytes 4..8, big-endian.
    cidx[7] = 99;

    final reader = DictReader(file.path);
    addTearDown(reader.close);
    await expectLater(
      () async => reader.importCidx(cidx),
      throwsA(isA<FormatException>()),
    );
  });

  test('rejects a cidx for a changed dictionary file', () async {
    final directory =
        await Directory.systemTemp.createTemp('dict_reader_cidx_changed_');
    addTearDown(() => directory.delete(recursive: true));
    final file = await _createFixture(directory);

    final source = DictReader(file.path);
    await source.initDict();
    final cidx = await source.exportCidx();
    await source.close();
    await file.writeAsBytes([0], mode: FileMode.append);

    final reader = DictReader(file.path);
    addTearDown(reader.close);
    await expectLater(
      () async => reader.importCidx(cidx),
      throwsA(isA<FormatException>()),
    );
  });

  test('rejects a truncated cidx', () async {
    final directory =
        await Directory.systemTemp.createTemp('dict_reader_cidx_trunc_');
    addTearDown(() => directory.delete(recursive: true));
    final file = await _createFixture(directory);

    final source = DictReader(file.path);
    await source.initDict();
    final cidx = await source.exportCidx();
    await source.close();

    final reader = DictReader(file.path);
    addTearDown(reader.close);
    await expectLater(
      () async => reader.importCidx(cidx.sublist(0, cidx.length - 3)),
      throwsA(isA<FormatException>()),
    );
  });

  group('Unicode NFC lookup', () {
    test('finds an NFD headword from an NFC query, keeping its spelling',
        () async {
      final directory =
          await Directory.systemTemp.createTemp('dict_reader_nfc_test_');
      addTearDown(() => directory.delete(recursive: true));
      final file = await _createFixture(
        directory,
        entries: [
          ('ingle\u0301s', 'spanish'),
          ('plain', 'P'),
        ],
      );

      final reader = DictReader(file.path);
      await reader.initDict();
      addTearDown(reader.close);

      expect(reader.exist('ingl\u00E9s'), isTrue);
      expect(reader.exist('ingle\u0301s'), isTrue);

      final offsets = await reader.locateAll('ingl\u00E9s');
      expect(offsets, hasLength(1));
      // Callers display this, so it must stay the dictionary's spelling.
      expect(offsets.single.keyText, 'ingle\u0301s');
      expect(await reader.readOneMdx(offsets.single), 'spanish');

      expect(reader.search('ingl'), ['ingle\u0301s']);
    });

    test('finds an NFC headword from an NFD query', () async {
      final directory =
          await Directory.systemTemp.createTemp('dict_reader_nfc_reverse_');
      addTearDown(() => directory.delete(recursive: true));
      final file = await _createFixture(
        directory,
        entries: [
          ('ingl\u00E9s', 'spanish'),
        ],
      );

      final reader = DictReader(file.path);
      await reader.initDict();
      addTearDown(reader.close);

      expect(reader.exist('ingle\u0301s'), isTrue);
      final offset = await reader.locate('ingle\u0301s');
      expect(offset, isNotNull);
      expect(offset!.keyText, 'ingl\u00E9s');
    });

    test('keeps both spellings when two headwords normalise alike', () async {
      final directory =
          await Directory.systemTemp.createTemp('dict_reader_nfc_collide_');
      addTearDown(() => directory.delete(recursive: true));
      final file = await _createFixture(
        directory,
        entries: [
          ('e\u0301', 'decomposed'),
          ('\u00E9', 'composed'),
        ],
      );

      final reader = DictReader(file.path);
      await reader.initDict();
      addTearDown(reader.close);

      final offsets = await reader.locateAll('\u00E9');
      expect(offsets, hasLength(2));
      expect(
        offsets.map((offset) => offset.keyText).toSet(),
        {'e\u0301', '\u00E9'},
      );
      expect(reader.search('\u00E9'), hasLength(2));
    });

    test('cidx round-trip keeps raw spellings and normalisation metadata',
        () async {
      final directory =
          await Directory.systemTemp.createTemp('dict_reader_nfc_cidx_');
      addTearDown(() => directory.delete(recursive: true));
      final file = await _createFixture(
        directory,
        entries: [
          ('ingle\u0301s', 'spanish'),
          ('plain', 'P'),
        ],
      );

      final source = DictReader(file.path);
      await source.initDict();
      final cidx = await source.exportCidx();
      await source.close();

      final parsed = parseCidx(cidx);
      expect(parsed.header.normalization, normalizationNfc);
      expect(parsed.header.unicodeVersion, normalizationUnicodeVersion);

      final imported = DictReader(file.path);
      addTearDown(imported.close);
      await imported.importCidx(cidx);

      expect(imported.exist('ingl\u00E9s'), isTrue);
      final offsets = await imported.locateAll('ingl\u00E9s');
      expect(offsets, hasLength(1));
      expect(offsets.single.keyText, 'ingle\u0301s');
      expect(await imported.readOneMdx(offsets.single), 'spanish');
      expect(imported.search('ingl'), ['ingle\u0301s']);

      // File-order iteration after a cidx import must also expose the raw
      // spelling, not the normalised key.
      final keys = await imported
          .readWithMdxData()
          .map((record) => record.keyText)
          .toList();
      expect(keys, ['ingle\u0301s', 'plain']);
    });

    test('cidx stores the original spelling only when it differs', () async {
      final directory =
          await Directory.systemTemp.createTemp('dict_reader_nfc_raw_');
      addTearDown(() => directory.delete(recursive: true));
      final file = await _createFixture(
        directory,
        entries: [
          // Already NFC: the key is its own spelling, so no duplicate.
          ('ingl\u00E9s', 'nfc'),
          // Decomposed: the key loses the U+0301, the spelling must survive.
          ('ingle\u0301s', 'nfd'),
          ('plain', 'ascii'),
        ],
      );

      final source = DictReader(file.path);
      await source.initDict();
      final cidx = await source.exportCidx();
      await source.close();

      final parsed = parseCidx(cidx);
      final withRaw = [
        for (var i = 0; i < parsed.entryOffsets.length; i++)
          if (cidxEntryAt(parsed.body, i, parsed.entryOffsets[i]).rawOffset !=
              null)
            i,
      ];
      expect(withRaw, hasLength(1));

      // Both spellings collapse to one key, and reading either returns the
      // spelling the dictionary actually uses.
      final imported = DictReader(file.path);
      addTearDown(imported.close);
      await imported.importCidx(cidx);
      final offsets = await imported.locateAll('ingl\u00E9s');
      expect(offsets.map((offset) => offset.keyText), hasLength(2));
      expect(await imported.readOneMdx(offsets.first), isNotEmpty);
    });

    test('rejects a cidx built with another Unicode table version', () async {
      final directory =
          await Directory.systemTemp.createTemp('dict_reader_nfc_stale_');
      addTearDown(() => directory.delete(recursive: true));
      final file = await _createFixture(directory);

      final source = DictReader(file.path);
      await source.initDict();
      final cidx = await source.exportCidx();
      await source.close();
      // unicodeVersion field: magic(4) version(4) collation(4)
      // normalization(4) -> bytes 16..20, big-endian.
      cidx[19] = 99;

      final reader = DictReader(file.path);
      addTearDown(reader.close);
      await expectLater(
        () async => reader.importCidx(cidx),
        throwsA(isA<FormatException>()),
      );
    });
  });
}
