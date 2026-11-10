// Measures REAL sheet sizes using the actual designs from OneDrive, so we
// know exactly how big an emailed order gets.  dart run tool/measure_sizes.dart
import 'dart:io';
import 'dart:typed_data';

import 'package:image/image.dart' as img;
import 'package:print_collage_tool/models/sheet_plan.dart';
import 'package:print_collage_tool/services/collage.dart';

Future<void> main() async {
  final dir = Directory(r'C:\Users\4001C\OneDrive\12 X 18');
  final locals = <File>[];
  await for (final e in dir.list(recursive: true)) {
    if (e is! File) continue;
    if (!RegExp(r'\.(jpg|jpeg|png)$', caseSensitive: false).hasMatch(e.path)) continue;
    // Skip OneDrive cloud placeholders (reading them would trigger a download).
    try {
      final raf = await e.open();
      final head = await raf.read(4);
      await raf.close();
      if (head.length < 4) continue;
      final len = await e.length();
      if (len < 50 * 1024) continue;
      locals.add(e);
    } catch (_) {}
    if (locals.length >= 4) break;
  }
  if (locals.length < 4) {
    print('Only ${locals.length} local designs — need 4');
    return;
  }
  print('Using: ${locals.map((f) => f.uri.pathSegments.last).join(", ")}\n');

  final designs = <String, Uint8List>{};
  for (var i = 0; i < 4; i++) {
    final raw = await locals[i].readAsBytes();
    final decoded = img.decodeImage(raw)!;
    print('source ${i + 1}: ${decoded.width}x${decoded.height}  '
        '${(raw.length / 1024 / 1024).toStringAsFixed(2)} MB');
    designs['D$i'] = CollageRenderer.preprocessDesign(raw);
  }
  print('');

  // Mixed sheet — the realistic worst case (4 different photos).
  final mixed = SheetPlan(slots: const ['D0', 'D1', 'D2', 'D3'], copies: 1);
  final bytes = await CollageRenderer.render(plan: mixed, designImages: designs);
  final mb = bytes.length / 1024 / 1024;
  final decoded = img.decodeJpg(bytes)!;
  print('RENDERED SHEET: ${decoded.width}x${decoded.height}, '
      '${mb.toStringAsFixed(2)} MB at current settings\n');

  print('--- projected ZIP size (JPEGs do not compress) ---');
  for (final n in [4, 6, 8, 10, 15, 20]) {
    final total = mb * n;
    final over = total > 25 ? '  <-- OVER Gmail 25 MB limit -> Drive link' : '';
    print('${n.toString().padLeft(2)} sheets: ${total.toStringAsFixed(1)} MB$over');
  }
}
