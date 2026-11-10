// Quick sanity check for the JFIF DPI stamp — runs on the desktop VM,
// no device needed:  dart run tool/check_dpi.dart
import 'dart:typed_data';

import 'package:image/image.dart' as img;
import 'package:print_collage_tool/models/sheet_plan.dart';
import 'package:print_collage_tool/services/collage.dart';

Future<void> main() async {
  // Tiny fake design image (solid color with a diagonal line).
  final design = img.Image(width: 400, height: 600, numChannels: 3);
  img.fill(design, color: img.ColorRgb8(180, 40, 90));
  img.drawLine(design,
      x1: 0, y1: 0, x2: 399, y2: 599, color: img.ColorRgb8(255, 255, 255));
  final designBytes = Uint8List.fromList(img.encodeJpg(design, quality: 90));

  final plan = SheetPlan(
    slots: const ['A', 'B', 'A', 'B'],
    copies: 1,
  );
  final sheet = await CollageRenderer.render(
    plan: plan,
    designImages: {'A': designBytes, 'B': designBytes},
  );

  // Parse the JFIF APP0 header back out.
  if (sheet[0] != 0xFF || sheet[1] != 0xD8) {
    print('FAIL: not a JPEG');
    return;
  }
  final isJfif = sheet[2] == 0xFF &&
      sheet[3] == 0xE0 &&
      sheet[6] == 0x4A &&
      sheet[7] == 0x46 &&
      sheet[8] == 0x49 &&
      sheet[9] == 0x46 &&
      sheet[10] == 0x00;
  if (!isJfif) {
    print('FAIL: no JFIF APP0 right after SOI');
    return;
  }
  final units = sheet[13];
  final xDensity = (sheet[14] << 8) | sheet[15];
  final yDensity = (sheet[16] << 8) | sheet[17];
  final decoded = img.decodeJpg(sheet)!;
  print('units=$units (1=dpi)  xDensity=$xDensity  yDensity=$yDensity');
  print('pixels=${decoded.width}x${decoded.height}');
  print('doc size at that dpi = '
      '${decoded.width / xDensity}" x ${decoded.height / yDensity}"');
  print('file size = ${(sheet.length / 1024 / 1024).toStringAsFixed(2)} MB');
  final ok = units == 1 &&
      xDensity == 350 &&
      yDensity == 350 &&
      decoded.width == 4200 &&
      decoded.height == 6300;
  print(ok ? 'PASS' : 'FAIL');
}
