# Dict_reader

Reading mdict files, support MDX/MDD file formats.

## Install

```sh
dart pub add dict_reader
```

## Usage

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
