import 'dart:io';

import 'package:dict_reader/dict_reader.dart';
import 'package:test/test.dart';

// Real-dictionary parity + measurement. Skipped when the Oxford file is
// not present (it is not part of this repository, so upstream CI skips
// this test). When present, it compares a scanned reader against a
// `.cidx`-imported reader on the same file, and records timings.
const oxfordPaths = [
  '/home/hatch/workspace/dict_test/牛津高阶英汉双解词典（第9版）- 带高清版图片/牛津高阶英汉双解词典（第9版）.mdx',
  '/home/hatch/.local/share/ciyue/dictionaries/牛津高阶英汉双解词典（第9版）.mdx',
];

void main() {
  test('oxford parity: scan vs cidx import', () async {
    final path = oxfordPaths.firstWhere(
      (p) => File(p).existsSync(),
      orElse: () => '',
    );
    if (path.isEmpty) {
      markTestSkipped('Oxford MDX not available on this machine');
    }

    final scanned = DictReader(path);
    final scanWatch = Stopwatch()..start();
    await scanned.initDict();
    scanWatch.stop();
    addTearDown(scanned.close);

    final exportWatch = Stopwatch()..start();
    final cidx = await scanned.exportCidx();
    exportWatch.stop();

    final imported = DictReader(path);
    final importWatch = Stopwatch()..start();
    await imported.importCidx(cidx);
    importWatch.stop();
    addTearDown(imported.close);

    await File('/tmp/cidx_oxford_measure.txt').writeAsString(
      'entries=${scanned.numEntries} '
      'scanMs=${scanWatch.elapsedMilliseconds} '
      'exportMs=${exportWatch.elapsedMilliseconds} '
      'importMs=${importWatch.elapsedMilliseconds} '
      'cidxBytes=${cidx.length} '
      'dictBytes=${await File(path).length()}\n',
    );

    // Harvest a deterministic sample of headwords via prefix search.
    final sample = <String>{};
    for (final prefix in ['a', 'th', 'un', 'pre', 'con', 'z', 'ox']) {
      sample.addAll(scanned.search(prefix, limit: 100));
    }
    sample.addAll(['hello', 'world', 'abandon', 'the', 'dictionary']);
    expect(sample.length, greaterThan(100));

    for (final word in sample) {
      expect(imported.exist(word), scanned.exist(word), reason: word);
      final scannedOffsets = await scanned.locateAll(word);
      final importedOffsets = await imported.locateAll(word);
      expect(importedOffsets.length, scannedOffsets.length, reason: word);
      for (var i = 0; i < scannedOffsets.length; i++) {
        expect(
          await imported.readOneMdx(importedOffsets[i]),
          await scanned.readOneMdx(scannedOffsets[i]),
          reason: '$word#$i',
        );
      }
    }
    for (final prefix in ['a', 'ab', 'th', 'un', 'pre', 'con', 'z']) {
      expect(
        imported.search(prefix, limit: 100).toSet(),
        scanned.search(prefix, limit: 100).toSet(),
        reason: 'prefix $prefix',
      );
    }
  });
}
