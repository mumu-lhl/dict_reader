import 'dart:typed_data';

/// Reads an unsigned integer of [byteWidth] bytes (1 or 2).
int readByte(List<int> buffer, int byteWidth, [int start = 0]) {
  if (byteWidth == 1) {
    return buffer[start];
  }
  return (buffer[start] << 8) | buffer[start + 1];
}

/// Reads a big-endian unsigned integer of [numberWidth] bytes (4 or 8).
int readNumber(List<int> buffer, int numberWidth, [int start = 0]) {
  var value = 0;
  for (var i = 0; i < numberWidth; i++) {
    value = (value << 8) | buffer[start + i];
  }
  return value;
}

/// Returns a slice of [data] from [start] to [end] without unnecessary copies.
List<int> sliceBytes(List<int> data, int start, int end) {
  if (data is Uint8List) {
    return Uint8List.sublistView(data, start, end);
  }
  return data.sublist(start, end);
}

/// Finds the index of the first 0 byte in [bytes] starting from [start].
int findByteTerminator(Uint8List bytes, int start) {
  var index = start;
  while (index < bytes.length && bytes[index] != 0) {
    index++;
  }
  return index;
}

/// Finds the index of the first UTF-16 NUL terminator (0x00 0x00) starting from [start].
int findUtf16Terminator(Uint8List bytes, int start) {
  var index = start;
  while (index + 1 < bytes.length &&
      (bytes[index] != 0 || bytes[index + 1] != 0)) {
    index += 2;
  }
  return index;
}
