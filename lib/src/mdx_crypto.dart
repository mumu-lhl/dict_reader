import 'dart:typed_data';

import 'package:blockchain_utils/crypto/crypto/hash/hash.dart';

/// Decrypts encrypted block data using MDict's XOR keystream algorithm.
Uint8List fastDecrypt(Uint8List data, Uint8List key) {
  final b = data;
  final keyLength = key.length;
  int previous = 0x36;

  for (int i = 0; i < b.length; i++) {
    int t = (b[i] >> 4 | b[i] << 4) & 0xff;
    t = t ^ previous ^ (i & 0xff) ^ key[i % keyLength];
    previous = b[i];
    b[i] = t;
  }

  return b;
}

/// Derives the 128-bit key for decrypting encrypted key block info.
Uint8List computeKeyBlockInfoKey(List<int> checksumBytes) {
  return Uint8List.fromList(
    RIPEMD128.hash(checksumBytes + [149, 54, 0, 0]),
  );
}
