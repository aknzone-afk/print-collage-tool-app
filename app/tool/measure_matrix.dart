// Size/quality matrix on REAL designs: is there a setting where a 10-sheet
// order fits Gmail's 25 MB limit without losing real detail?
// dart run tool/measure_matrix.dart
import 'dart:io';
import 'dart:typed_data';

import 'package:image/image.dart' as img;

Future<void> main() async {
  final dir = Directory(r'C:\Users\4001C\OneDrive\12 X 18');
  final locals = <File>[];
  await for (final e in dir.list(recursive: true)) {
    if (e is! File) continue;
    if (!RegExp(r'\.(jpg|jpeg|png)$', caseSensitive: false).hasMatch(e.path)) continue;
    if (await e.length() < 50 * 1024) continue;
    locals.add(e);
    if (locals.length >= 4) break;
  }
  final sources = <img.Image>[];
  for (final f in locals) {
    sources.add(img.decodeImage(await f.readAsBytes())!);
  }

  // dpi -> (sheetW, sheetH, slotW, slotH)
  const dpis = [300, 350];
  const qualities = [95, 90, 85, 80];
  const gutter = 12;

  print('source: ${sources[0].width}x${sources[0].height} (= ${sources[0].width ~/ 6} DPI in a 6" slot)\n');
  print('DPI   Q    sheet px      1 sheet    x6      x10     x20    10-sheet verdict');
  print('---------------------------------------------------------------------------');
  for (final dpi in dpis) {
    final sheetW = 12 * dpi, sheetH = 18 * dpi;
    final slotW = 6 * dpi, slotH = 9 * dpi;
    final innerW = slotW - gutter ~/ 2, innerH = slotH - gutter ~/ 2;
    // Build the canvas once per dpi.
    final canvas = img.Image(width: sheetW, height: sheetH, numChannels: 3);
    img.fill(canvas, color: img.ColorRgb8(255, 255, 255));
    for (var i = 0; i < 4; i++) {
      final src = sources[i];
      final srcAspect = src.width / src.height;
      final dstAspect = innerW / innerH;
      int nw, nh;
      if (srcAspect > dstAspect) {
        nw = innerW;
        nh = (innerW / srcAspect).round();
      } else {
        nh = innerH;
        nw = (innerH * srcAspect).round();
      }
      final isDown = nw < src.width || nh < src.height;
      final fitted = img.copyResize(src,
          width: nw,
          height: nh,
          interpolation: isDown ? img.Interpolation.average : img.Interpolation.cubic);
      final col = i % 2, row = i ~/ 2;
      final left = col * slotW + (col == 1 ? gutter ~/ 2 : 0);
      final top = row * slotH + (row == 1 ? gutter ~/ 2 : 0);
      img.compositeImage(canvas, fitted,
          dstX: left + (innerW - fitted.width) ~/ 2,
          dstY: top + (innerH - fitted.height) ~/ 2);
    }
    for (final q in qualities) {
      final Uint8List b = Uint8List.fromList(img.encodeJpg(canvas, quality: q));
      final mb = b.length / 1024 / 1024;
      final ten = mb * 10;
      final verdict = ten <= 25 ? 'FITS in one email' : '${(ten / 20).ceil()} emails needed';
      print('${dpi.toString().padRight(5)} ${q.toString().padRight(4)} '
          '${'${sheetW}x$sheetH'.padRight(13)} '
          '${mb.toStringAsFixed(2).padLeft(5)} MB  '
          '${(mb * 6).toStringAsFixed(0).padLeft(4)}MB  '
          '${ten.toStringAsFixed(0).padLeft(4)}MB  '
          '${(mb * 20).toStringAsFixed(0).padLeft(4)}MB   $verdict');
    }
    print('');
  }
}
