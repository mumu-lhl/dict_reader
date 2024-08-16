# Dict_reader

![Pub Version](https://img.shields.io/pub/v/dict_reader)

[English](./README.md) | 中文

读取 mdict 文件，支持 MDX/MDD 文件格式。

## 缺点

这些缺点不影响一般使用 :)

* 校验 ❌
* 加密 ❌
* lzo 压缩 ❌
* 3.0 版本格式 ❌

## 安装

```sh
dart pub add dict_reader
```

## 使用

### 直接读取数据

```dart
import 'package:dict_reader/dict_reader.dart';

void main() async {
  final dictReader = DictReader("MDX FILE PATH");
  await dictReader.init();

  await for (final (keyText, data) in dictReader.read(true)) {
    print("$keyText, $data");
  }
}
```

### 读取数据 offset，之后读取数据

```dart
import 'package:dict_reader/dict_reader.dart';

void main() async {
  final dictReader = DictReader("MDX FILE PATH");
  await dictReader.init();

  final map = <String, (int, int, int, int)>{};
  await for (final (keyText, offset) in dictReader.read()) {
    map[keyText] = offset;
  }

  final offset = map["go"];
  print(await dictReader.readOne(offset!.$1, offset.$2, offset.$3, offset.$4));
}
```

### 当已保存数据 offset，读取数据

```dart
import 'package:dict_reader/dict_reader.dart';

// ...

void main() async {
  // ...

  final dictReader = DictReader("MDX FILE PATH");
  // Pass false to reduce initialization time
  await dictReader.init(false);

  final offset = map["go"];
  print(await dictReader.readOne(offset!.$1, offset.$2, offset.$3, offset.$4));
}
```
