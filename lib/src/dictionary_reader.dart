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

  /// Opens a byte stream for reading this article or resource data, optionally
  /// constrained to the byte range from [start] (inclusive) up to [end] (exclusive).
  Future<Stream<List<int>>> openRead({int? start, int? end}) async {
    final bytes = await readData();
    final length = bytes.length;
    final s = (start ?? 0).clamp(0, length);
    final e = (end ?? length).clamp(s, length);
    if (s >= e) return Stream.value(Uint8List(0));
    return Stream.value(Uint8List.sublistView(bytes, s, e));
  }
}

/// A search result returned by [DictionaryReader.searchFulltext].
class DictSearchResult {
  /// The matching article entry.
  final DictArticle article;

  /// A text snippet surrounding the match with contextual excerpts.
  final String snippet;

  /// Relevance score (higher is more relevant).
  final double score;

  const DictSearchResult({
    required this.article,
    required this.snippet,
    this.score = 1.0,
  });

  @override
  String toString() =>
      'DictSearchResult(${article.headword}, score: $score, snippet: "$snippet")';
}

/// Helper function to extract a text snippet around [query].
String extractSnippet(String text, String query, {int radius = 40}) {
  final clean = text
      .replaceAll(RegExp(r'<[^>]+>'), ' ')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
  final index = clean.toLowerCase().indexOf(query.toLowerCase());
  if (index < 0) {
    if (clean.length <= radius * 2) return clean;
    return '${clean.substring(0, radius * 2)}...';
  }
  final start = (index - radius).clamp(0, clean.length);
  final end = (index + query.length + radius).clamp(0, clean.length);
  final prefix = start > 0 ? '...' : '';
  final suffix = end < clean.length ? '...' : '';
  return '$prefix${clean.substring(start, end)}$suffix';
}

/// A unified interface implemented by all dictionary formats
/// (MDX/MDD, StarDict, and ZIM).
abstract class DictionaryReader {
  /// The title or display name of the dictionary.
  String get title;

  /// Total number of headwords/entries in the dictionary.
  int get wordCount;

  /// All headwords in the dictionary.
  List<String> get words;

  /// Returns the headword at [index].
  String wordAt(int index);

  /// Checks whether [word] exists in the dictionary.
  FutureOr<bool> exist(String word);

  /// Prefix search returning up to [limit] matching headwords.
  List<String> search(String query, {int? limit});

  /// Performs full-text search across article contents, returning matching
  /// entries ranked with snippets.
  Future<List<DictSearchResult>> searchFulltext(
    String query, {
    int limit = 20,
  });

  /// Looks up [word] and returns matching articles.
  Future<List<DictArticle>> lookup(String word);

  /// Retrieves binary resource data (image, audio, CSS, font) by [path].
  Future<Uint8List?> getResource(String path);

  /// Opens a byte stream for the resource at [path], optionally constrained to
  /// the byte range from [start] (inclusive) up to [end] (exclusive).
  ///
  /// Returns `null` if the resource does not exist.
  Future<Stream<List<int>>?> getResourceStream(
    String path, {
    int? start,
    int? end,
  }) async {
    final bytes = await getResource(path);
    if (bytes == null) return null;
    final length = bytes.length;
    final s = (start ?? 0).clamp(0, length);
    final e = (end ?? length).clamp(s, length);
    if (s >= e) return Stream.value(Uint8List(0));
    return Stream.value(Uint8List.sublistView(bytes, s, e));
  }

  /// Exports the pre-computed index cache (`.cidx`) for this dictionary.
  Future<Uint8List> exportCidx() =>
      throw UnsupportedError('exportCidx is not supported for $runtimeType');

  /// Imports a pre-computed index cache (`.cidx`) for this dictionary.
  Future<void> importCidx(Uint8List bytes) =>
      throw UnsupportedError('importCidx is not supported for $runtimeType');

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
