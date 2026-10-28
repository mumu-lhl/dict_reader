/// Thrown when a dictionary block uses a compression method this package
/// cannot decode.
///
/// MDict stores the method in the low nibble of the first word of a block:
/// `0` is uncompressed, `2` is zlib, and `1` is LZO, which is not implemented
/// here. LZO dictionaries are rare but exist, and a caller that only sees
/// "the file is unreadable" cannot tell the user what to do about it.
///
/// Extends [FormatException] so existing handling of unreadable files keeps
/// working; the message keeps the old wording so logs stay greppable.
class UnsupportedCompressionException extends FormatException {
  /// The compression method found in the block: 1 = LZO, 2 = zlib.
  final int method;

  UnsupportedCompressionException(this.method)
      : super("Compression method not supported (method $method)");
}
