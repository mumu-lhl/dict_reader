# Dict_reader

读取 mdict 文件，支持 MDX/MDD 文件格式。

## 安装

```sh
dart pub add dict_reader
```

## 使用

```dart
import 'package:dict_reader/dict_reader.dart';

void main() async {
  final dictReader =
      DictReader("MDX FILE PATH");
  await dictReader.init();

  await for (final (keyText, data) in dictReader.read()) {
    print("$keyText, $data");
  }
}
```
