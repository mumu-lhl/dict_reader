import 'package:dict_reader/dict_reader.dart';
import 'package:test/test.dart';

void main() {
  group('normalizeKey', () {
    test('returns pure ASCII unchanged', () {
      expect(normalizeKey('hoped'), 'hoped');
      expect(normalizeKey('ortho-axis'), 'ortho-axis');
      expect(normalizeKey(''), '');
    });

    test('composes a decomposed acute accent', () {
      expect(normalizeKey('ingle\u0301s'), 'ingl\u00E9s');
    });

    test('leaves an already composed word unchanged', () {
      expect(normalizeKey('ingl\u00E9s'), 'ingl\u00E9s');
    });

    test('treats both spellings as the same key', () {
      expect(normalizeKey('ingle\u0301s'), normalizeKey('ingl\u00E9s'));
      expect(normalizeKey('e\u0301pe\u0301e'), normalizeKey('\u00E9p\u00E9e'));
    });

    test('is idempotent', () {
      const decomposed = 'A\u030Angstro\u0308m';
      final once = normalizeKey(decomposed);
      expect(normalizeKey(once), once);
    });

    test('composes decomposed Hangul syllables', () {
      // U+1100 HANGUL CHOSEONG KIYEOK + U+1161 HANGUL JUNGSEONG A.
      expect(normalizeKey('\u1100\u1161'), '\uAC00');
    });

    test('leaves CJK headwords untouched', () {
      expect(normalizeKey('懷刷'), '懷刷');
      expect(normalizeKey('ふうぞく'), 'ふうぞく');
    });

    test('keeps rare supplementary-plane characters', () {
      // U+2CEB0, outside the BMP: must survive a UTF-16 round trip.
      expect(normalizeKey('\u{2CEB0}'), '\u{2CEB0}');
    });

    test('reports whether a key is already normalised', () {
      expect(isNormalizedKey('ingl\u00E9s'), isTrue);
      expect(isNormalizedKey('ingle\u0301s'), isFalse);
    });
  });

  group('lookupKeyOf', () {
    test('reuses the input instance when it is already NFC', () {
      const composed = 'ingl\u00E9s';
      expect(identical(lookupKeyOf(composed), composed), isTrue);

      const ascii = 'hoped';
      expect(identical(lookupKeyOf(ascii), ascii), isTrue);
    });

    test('returns the composed form for a decomposed input', () {
      const decomposed = 'ingle\u0301s';
      final lookup = lookupKeyOf(decomposed);
      expect(lookup, 'ingl\u00E9s');
      expect(identical(lookup, decomposed), isFalse);
    });
  });

  group('cidx normalisation metadata', () {
    test('uses a stable, non-zero algorithm id', () {
      expect(normalizationNone, 0);
      expect(normalizationNfc, 1);
    });

    test('records the Unicode table version as major * 100 + minor', () {
      expect(normalizationUnicodeVersion, greaterThanOrEqualTo(1500));
      expect(normalizationUnicodeVersion % 100, lessThan(100));
    });
  });
}
