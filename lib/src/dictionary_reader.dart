import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'dict_reader_base.dart';
import 'stardict_reader.dart';
import 'zim_reader.dart';

/// A unified article/entry returned by [DictionaryReader.lookup].
abstract class DictArticle {
  /// The headword or title of the entry.
  String get headword;

  /// The MIME type of the content (e.g. "text/html", "text/plain").
  String get mimeType;

  /// The dictionary format of this entry (e.g. "mdx", "stardict", "zim").
  String get format;

  /// The underlying format-specific entry object (e.g. [ZimEntry], [StarDictEntry],
  /// or [RecordOffsetInfo]).
  dynamic get raw;

  /// Reads the text content of the article (UTF-8 decoded).
  Future<String> readText();

  /// Reads the raw data bytes of the article.
  Future<Uint8List> readData();
}

/// A unified interface implemented by all dictionary formats
/// (MDX/MDD, StarDict, and ZIM).
abstract interface class DictionaryReader {
  /// The title or display name of the dictionary.
  String get title;

  /// Total number of headwords/entries in the dictionary.
  int get wordCount;

  /// Checks whether [word] exists in the dictionary.
  FutureOr<bool> exist(String word);

  /// Prefix search returning up to [limit] matching headwords.
  List<String> search(String query, {int? limit});

  /// Looks up [word] and returns matching articles.
  Future<List<DictArticle>> lookup(String word);

  /// Retrieves binary resource data (image, audio, CSS, font) by [path].
  Future<Uint8List?> getResource(String path);

  /// Closes the dictionary and releases resources.
  Future<void> close();

  /// Opens any supported dictionary file (.mdx, .ifo, .zim, etc.) and returns
  /// an initialized [DictionaryReader].
  ///
  /// For MDX dictionaries, if [mddPath] is provided (or a companion `.mdd` file
  /// exists with the same base name), it will be automatically attached for
  /// resource lookups.
  static Future<DictionaryReader> open(
    String path, {
    String? mddPath,
  }) async {
    final lower = path.toLowerCase();

    if (lower.endsWith('.zim')) {
      final reader = ZimReader(path);
      await reader.init();
      return reader;
    }

    if (lower.endsWith('.ifo') ||
        lower.endsWith('.idx') ||
        lower.endsWith('.dict') ||
        lower.endsWith('.dict.dz')) {
      var basePath = path;
      for (final ext in const ['.ifo', '.idx', '.dict.dz', '.dict']) {
        if (basePath.toLowerCase().endsWith(ext)) {
          basePath = basePath.substring(0, basePath.length - ext.length);
          break;
        }
      }
      final reader = StarDictReader(basePath);
      await reader.init();
      return reader;
    }

    if (lower.endsWith('.mdx') || lower.endsWith('.mdd')) {
      final reader = DictReader(path);
      await reader.initDict();

      // Check companion MDD
      if (mddPath != null && File(mddPath).existsSync()) {
        final mdd = DictReader(mddPath);
        await mdd.initDict();
        reader.companionMdd = mdd;
      } else if (lower.endsWith('.mdx')) {
        final candidateMdd = '${path.substring(0, path.length - 4)}.mdd';
        final candidateMddUpper = '${path.substring(0, path.length - 4)}.MDD';
        String? foundMdd;
        if (File(candidateMdd).existsSync()) {
          foundMdd = candidateMdd;
        } else if (File(candidateMddUpper).existsSync()) {
          foundMdd = candidateMddUpper;
        }
        if (foundMdd != null) {
          final mdd = DictReader(foundMdd);
          await mdd.initDict();
          reader.companionMdd = mdd;
        }
      }
      return reader;
    }

    // If a directory or base path without extension was given, check for StarDict
    if (File('$path.ifo').existsSync()) {
      final reader = StarDictReader(path);
      await reader.init();
      return reader;
    }

    throw ArgumentError(
        'Unsupported dictionary format or file not found: $path');
  }
}
