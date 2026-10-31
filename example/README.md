# Example

English | [中文](./README_CN.md)

## Initialize with `initDict`

The `initDict` method allows for more granular control over the initialization process.

```dart
import 'package:dict_reader/dict_reader.dart';

void main() async {
  final dictReader = DictReader("MDX FILE PATH");

  // Only initialize header
  await dictReader.initDict(readKeys: false, readRecordBlockInfo: false);

  // ... perform operations

  // Full initialization
  await dictReader.initDict();

  // ... perform other operations

  await dictReader.close();
}
```

The parameters for `initDict` are:
- `readKeys`: Whether to read the key list. Defaults to `true`.
- `readRecordBlockInfo`: Whether to read record block information. Defaults to `true`.
- `readHeader`: Whether to read the dictionary header. Defaults to `true`.

## Locate

```dart
import 'package:dict_reader/dict_reader.dart';

void main() async {
  final dictReader = DictReader("MDX FILE PATH");
  await dictReader.initDict();

  final offsetInfo = await dictReader.locate("go");
  print(await dictReader.readOneMdx(offsetInfo!));

  await dictReader.close();
}
```

## Search

```dart
import 'package:dict_reader/dict_reader.dart';

void main() async {
  final dictReader = DictReader("MDX FILE PATH");
  await dictReader.initDict();

  final keys = dictReader.search("go");
  print(keys);

  final keysWithLimit = dictReader.search("go", limit: 1);
  print(keysWithLimit);

  await dictReader.close();
}
```

## Exist

```dart
import 'package:dict_reader/dict_reader.dart';

void main() async {
  final dictReader = DictReader("MDX FILE PATH");
  await dictReader.initDict();

  final keyExists = dictReader.exist("go");
  print(keyExists);

  final keyDoesNotExist = dictReader.exist("non-existent-key");
  print(keyDoesNotExist);

  await dictReader.close();
}
```

## Read Data Directly

```dart
import 'package:dict_reader/dict_reader.dart';

void main() async {
  final dictReader = DictReader("MDX FILE PATH");
  await dictReader.initDict();

  await for (final MdxRecord(:keyText, :data) in dictReader.readWithMdxData()) {
    print("$keyText, $data");
  }

  await dictReader.close();
}
```

## Read Data Offset, Read Data Later

```dart
import 'package:dict_reader/dict_reader.dart';

void main() async {
  final dictReader = DictReader("MDX FILE PATH");
  await dictReader.initDict();

  final map = <String, RecordOffsetInfo>{};
  await for (final offsetInfo in dictReader.readWithOffset()) {
    map[offsetInfo.keyText] = offsetInfo;
  }

  final offsetInfo = map["go"];
  print(await dictReader.readOneMdx(offsetInfo!));

  await dictReader.close();
}
```

## Read Data After Stored Data Offset

```dart
import 'package:dict_reader/dict_reader.dart';

// ...

void main() async {
  // ...

  final dictReader = DictReader("MDX FILE PATH");
  // Pass false to reduce initialization time
  await dictReader.initDict(readKeys: false, readRecordBlockInfo: false);

  final offsetInfo = map["go"];
  print(await dictReader.readOneMdx(offsetInfo!));

  await dictReader.close();
}
```

## StarDict

```dart
import 'package:dict_reader/dict_reader.dart';

void main() async {
  final reader = StarDictReader("/path/to/dict"); // path without .ifo extension
  await reader.init();

  print('Book name: ${reader.bookName}');
  print('Word count: ${reader.wordCount}');

  final entries = await reader.lookup("hello");
  for (final entry in entries) {
    for (final field in entry.fields) {
      if (field.isText) {
        print('${field.type}: ${field.text}');
      }
    }
  }

  await reader.close();
}
```

## ZIM

```dart
import 'package:dict_reader/dict_reader.dart';

void main() async {
  final reader = ZimReader("/path/to/wikipedia.zim");
  await reader.init();

  print('Title: ${reader.title}');
  print('Description: ${reader.description}');
  print('Article count: ${reader.wordCount}');

  // Lookup article (follows redirects by default)
  final entries = await reader.lookup("Apple");
  for (final entry in entries) {
    print('Title: ${entry.title}');
    final html = await entry.readText();
    print(html);
  }

  // Prefix suggestions
  final suggestions = reader.search("app", limit: 5);
  print('Suggestions: $suggestions');

  // Retrieve media/image resource by path
  final imageBytes = await reader.readDataByPath("I/logo.png");

  await reader.close();
}
```
