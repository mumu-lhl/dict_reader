import 'package:unorm_dart/unorm_dart.dart' as unorm;

/// Unicode NFC, see [normalizeKey].
const int normalizationNfc = 1;

/// Version of the Unicode character data behind [normalizeKey], encoded as
/// `major * 100 + minor` (18.0 -> 1800).
///
/// It is written into `.cidx` headers so an index built with older tables is
/// rebuilt instead of being silently reused after a `unorm_dart` upgrade. Bump
/// this together with the dependency, never on our own schedule.
const int normalizationUnicodeVersion = 1800;

/// Returns [raw] in Unicode NFC.
///
/// Dictionary headwords are authors' output, not normalised data: the same
/// visible word may be stored as `é` (U+00E9) or as `e` + U+0301. A lookup has
/// to treat both spellings as one key, otherwise a query only hits the
/// dictionaries that happen to use the same encoding as whatever produced the
/// input (keyboard, clipboard, PDF extractor).
///
/// The result is only ever used for matching. Callers must keep the original
/// key for display: normalising the visible headword would rewrite Japanese or
/// Vietnamese glyphs in the UI.
///
/// ASCII input is returned unchanged without touching the tables (the common
/// case for most dictionaries), and any failure falls back to [raw] so a
/// normalisation bug can never turn a lookup into an exception.
String normalizeKey(String raw) {
  if (raw.isEmpty) return raw;

  for (var i = 0; i < raw.length; i++) {
    if (raw.codeUnitAt(i) > 0x7F) {
      try {
        return unorm.nfc(raw);
      } catch (_) {
        // An unnormalised miss is exactly the behaviour before this existed,
        // while a thrown exception would abort the whole lookup.
        return raw;
      }
    }
  }

  // Pure ASCII is already NFC.
  return raw;
}

/// [normalizeKey], but returns [raw] itself when the value is unchanged.
///
/// The in-memory index holds one normalised key per headword. `unorm.nfc`
/// allocates a new string even when the input was already NFC, and keeping
/// those copies would roughly double the key list of a Japanese, Korean or
/// Vietnamese dictionary. Only value equality matters to the index, so the
/// original instance is reused whenever it already matches.
String lookupKeyOf(String raw) {
  final normalized = normalizeKey(raw);
  return normalized == raw ? raw : normalized;
}

/// Whether [value] is already in NFC.
///
/// Used by tests and by the scan statistics that report how many headwords a
/// dictionary needed rewriting.
bool isNormalizedKey(String value) => normalizeKey(value) == value;
