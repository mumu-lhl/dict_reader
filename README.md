# Dict_reader

![Pub Version](https://img.shields.io/pub/v/dict_reader)

English | [中文](./README_CN.md)

Reading mdict files, support MDX/MDD file formats.

## Disadvantages

These drawbacks don't affect general use :)

* checksum ❌
* lzo compression ❌
* 3.0 version format ❌
* record block encrypted ❌

## Install

```sh
dart pub add dict_reader
```

## Usage

### Read Data Directly

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

### Read Data Offset, Read Data Later

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

### Read Data After Stored Data Offset

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
