// Verifies the Isolate.run worker path used by the phone pipeline:
// renderSheetToFile inside a spawned isolate, exactly like phase 2 does.
// dart run tool/check_isolate_render.dart
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:image/image.dart' as img;
import 'package:print_collage_tool/services/collage.dart';

Future<void> main() async {
  final tmpDir = Directory.systemTemp.createTempSync('sheet_test');
  // Two fake slot-sized designs on disk (like the design cache).
  for (var i = 0; i < 2; i++) {
    final d = img.Image(width: 500, height: 750, numChannels: 3);
    img.fill(d, color: img.ColorRgb8(40 + i * 120, 90, 160));
    File('${tmpDir.path}/D$i.jpg')
        .writeAsBytesSync(img.encodeJpg(d, quality: 90));
  }
  final slots = ['D0', 'D1', 'D1', 'D0'];
  final paths = {
    'D0': '${tmpDir.path}/D0.jpg',
    'D1': '${tmpDir.path}/D1.jpg',
  };
  final out = '${tmpDir.path}/sheet_0.jpg';

  final sw = Stopwatch()..start();
  await Isolate.run(() => CollageRenderer.renderSheetToFile(
        slots: slots,
        designPaths: paths,
        outPath: out,
      ));
  sw.stop();

  final bytes = Uint8List.fromList(File(out).readAsBytesSync());
  final decoded = img.decodeJpg(bytes)!;
  final dpiOk = bytes[13] == 1 &&
      ((bytes[14] << 8) | bytes[15]) == 350 &&
      ((bytes[16] << 8) | bytes[17]) == 350;
  print('worker isolate render: ${decoded.width}x${decoded.height} '
      'in ${sw.elapsedMilliseconds} ms, dpiTag=$dpiOk, '
      '${(bytes.length / 1024 / 1024).toStringAsFixed(2)} MB');
  print(decoded.width == 4200 && decoded.height == 6300 && dpiOk
      ? 'PASS'
      : 'FAIL');
  tmpDir.deleteSync(recursive: true);
}
