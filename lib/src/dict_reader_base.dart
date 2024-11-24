import "mdx.dart";
import "slob.dart";

class DictReader {
  late final DictReaderBase _dict;

  DictReader(String path) {
    if (path.endsWith(".mdx")) {
      _dict = MDX(path);
    } else if (path.endsWith(".mdd")) {
      _dict = Slob(path);
    }
  }

  Future<void> init() {
    return _dict.init();
  }

  Stream<(String, dynamic)> read([bool returnData = false]) {
    return _dict.read(returnData);
  }

  Future<dynamic> readOne(
      int offset, int startOffset, int endOffset, int compressedSize) {
    return _dict.readOne(offset, startOffset, endOffset, compressedSize);
  }

  Future<void> close() {
    return _dict.close();
  }
}

abstract class DictReaderBase {
  Future<void> init();
  Future<void> close();
  Stream<(String, dynamic)> read([bool returnData = false]);
  Future<dynamic> readOne(
      int offset, int startOffset, int endOffset, int compressedSize);
}
