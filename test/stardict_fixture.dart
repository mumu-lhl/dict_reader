import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// Builds small StarDict dictionaries on disk for tests.
///
/// An entry spec is a list of (type, value) pairs where value is a String
/// for text (lowercase) types and a byte list for binary (uppercase) types.
/// When [sameTypeSequence] is null the type markers are embedded in the
/// .dict data; otherwise the data holds bare fields in sequence order.
class StarDictFixtureBuilder {
  final List<String> words = [];
  final List<List<(String, Object)>> entries = [];
  final List<(String, int)> synonyms = [];

  void add(String word, List<(String, Object)> fields) {
    words.add(word);
    entries.add(fields);
  }

  void addSynonym(String synonym, int targetWordIndex) {
    synonyms.add((synonym, targetWordIndex));
  }

  Uint8List _encodeEntry(
    List<(String, Object)> fields,
    String? sameTypeSequence,
  ) {
    final out = BytesBuilder();
    for (var i = 0; i < fields.length; i++) {
      final (type, value) = fields[i];
      if (sameTypeSequence == null) {
        out.addByte(type.codeUnitAt(0));
      }
      if (value is String) {
        out.add(utf8.encode(value));
        out.addByte(0);
      } else if (value is List<int>) {
        final header = ByteData(4)..setUint32(0, value.length, Endian.big);
        out.add(header.buffer.asUint8List());
        out.add(value);
      }
    }
    return out.takeBytes();
  }

  /// Writes the dictionary files under [dir] with base name [name] and
  /// returns the base path (no extension). Set [dictZip] to store the data
  /// as `.dict.dz`, and [offsetBits] to 64 for a 3.0-style 64-bit index.
  Future<String> write(
    Directory dir,
    String name, {
    String? sameTypeSequence,
    bool dictZip = false,
    int offsetBits = 32,
    int dictZipChunkLength = 16,
  }) async {
    final dictBytes = BytesBuilder();
    final locations = <(int, int)>[];
    for (final entry in entries) {
      final encoded = _encodeEntry(entry, sameTypeSequence);
      locations.add((dictBytes.length, encoded.length));
      dictBytes.add(encoded);
    }
    final dictData = dictBytes.takeBytes();

    final idx = BytesBuilder();
    for (var i = 0; i < words.length; i++) {
      idx.add(utf8.encode(words[i]));
      idx.addByte(0);
      final (offset, size) = locations[i];
      if (offsetBits == 64) {
        idx.add((ByteData(8)..setUint64(0, offset, Endian.big)).buffer
            .asUint8List());
      } else {
        idx.add((ByteData(4)..setUint32(0, offset, Endian.big)).buffer
            .asUint8List());
      }
      idx.add((ByteData(4)..setUint32(0, size, Endian.big)).buffer
          .asUint8List());
    }
    final idxData = idx.takeBytes();

    final base = '${dir.path}/$name';
    await File('$base.idx').writeAsBytes(idxData);
    if (dictZip) {
      await File('$base.dict.dz').writeAsBytes(
        buildDictZip(dictData, chunkLength: dictZipChunkLength),
      );
    } else {
      await File('$base.dict').writeAsBytes(dictData);
    }
    if (synonyms.isNotEmpty) {
      final syn = BytesBuilder();
      for (final (word, target) in synonyms) {
        syn.add(utf8.encode(word));
        syn.addByte(0);
        syn.add((ByteData(4)..setUint32(0, target, Endian.big)).buffer
            .asUint8List());
      }
      await File('$base.syn').writeAsBytes(syn.takeBytes());
    }

    final ifo = StringBuffer()
      ..writeln("StarDict's dict ifo file")
      ..writeln('version=${offsetBits == 64 ? '3.0.0' : '2.4.2'}')
      ..writeln('bookname=Test Dictionary')
      ..writeln('wordcount=${words.length}')
      ..writeln('synwordcount=${synonyms.length}')
      ..writeln('idxfilesize=${idxData.length}')
      ..writeln('author=Fixture')
      ..writeln('description=A test dictionary');
    if (offsetBits == 64) ifo.writeln('idxoffsetbits=64');
    if (sameTypeSequence != null) {
      ifo.writeln('sametypesequence=$sameTypeSequence');
    }
    await File('$base.ifo').writeAsString(ifo.toString());
    return base;
  }
}

/// Wraps [data] in a dictzip gzip member: an "RA" extra field describing
/// raw-deflate chunks of [chunkLength] uncompressed bytes each.
Uint8List buildDictZip(Uint8List data, {required int chunkLength}) {
  final chunks = <Uint8List>[];
  for (var start = 0; start < data.length; start += chunkLength) {
    final end = start + chunkLength > data.length
        ? data.length
        : start + chunkLength;
    chunks.add(
      Uint8List.fromList(
        ZLibEncoder(raw: true).convert(Uint8List.sublistView(data, start, end)),
      ),
    );
  }
  if (chunks.isEmpty) chunks.add(Uint8List.fromList(ZLibEncoder(raw: true).convert(const <int>[])));

  // RA subfield: SI1 SI2 SLEN(LE) then version(2) chlen(2) chcnt(2) and
  // chcnt uint16 compressed lengths.
  final raDataLength = 6 + chunks.length * 2;
  final extra = BytesBuilder()
    ..addByte(0x52) // 'R'
    ..addByte(0x41) // 'A'
    ..add((ByteData(2)..setUint16(0, raDataLength, Endian.little)).buffer
        .asUint8List())
    ..add((ByteData(2)..setUint16(0, 1, Endian.little)).buffer.asUint8List())
    ..add((ByteData(2)..setUint16(0, chunkLength, Endian.little)).buffer
        .asUint8List())
    ..add((ByteData(2)..setUint16(0, chunks.length, Endian.little)).buffer
        .asUint8List());
  for (final chunk in chunks) {
    extra.add((ByteData(2)..setUint16(0, chunk.length, Endian.little)).buffer
        .asUint8List());
  }
  final extraBytes = extra.takeBytes();

  final out = BytesBuilder()
    ..add([0x1f, 0x8b, 8, 0x04]) // magic, deflate, FEXTRA
    ..add([0, 0, 0, 0]) // mtime
    ..add([0, 3]) // xfl, os=unix
    ..add((ByteData(2)..setUint16(0, extraBytes.length, Endian.little)).buffer
        .asUint8List())
    ..add(extraBytes);
  for (final chunk in chunks) {
    out.add(chunk);
  }
  // Trailer: crc32 (unchecked by the reader) + ISIZE.
  out.add([0, 0, 0, 0]);
  out.add((ByteData(4)..setUint32(0, data.length, Endian.little)).buffer
      .asUint8List());
  return out.takeBytes();
}
