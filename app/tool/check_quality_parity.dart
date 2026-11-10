// Quality-parity check between the OLD pure-Dart render path and the NEW
// Android-native path, runnable on desktop:
//   * upscaler:  Dart cubic (old)  vs  bilinear (Android createScaledBitmap)
//   * encoder:   Dart encodeJpg q90 4:2:0 (old)  vs  libjpeg-turbo q90 4:2:0
//     (what Android/Skia uses — exercised via Pillow in check_quality_parity.py)
// PSNR > 40 dB is the standard "visually indistinguishable" bar for photos.
//
// Usage: dart run tool/check_quality_parity.dart <design.jpg> <scratchDir>
// Then:  python tool/check_quality_parity.py <scratchDir>
// Then:  dart run tool/check_quality_parity.dart --stamp <scratchDir>
// Then:  python tool/check_quality_parity.py --dpi <scratchDir>
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:image/image.dart' as img;

const fitW = 2094; // CollageRenderer.innerSlotWidthPx
const fitH = 3144; // CollageRenderer.innerSlotHeightPx

double psnr(img.Image x, img.Image y) {
  final a = x.convert(numChannels: 3, format: img.Format.uint8).toUint8List();
  final b = y.convert(numChannels: 3, format: img.Format.uint8).toUint8List();
  if (a.length != b.length) throw StateError('dim mismatch');
  var se = 0.0;
  for (var i = 0; i < a.length; i++) {
    final d = a[i] - b[i];
    se += (d * d).toDouble();
  }
  final mse = se / a.length;
  if (mse == 0) return 99;
  return 10 * log(255 * 255 / mse) / ln10;
}

/// Same JFIF APP0 density patch the app applies (mirrors _stampDpi).
Uint8List stampDpi(Uint8List jpeg, int dpiValue) {
  final hi = (dpiValue >> 8) & 0xFF;
  final lo = dpiValue & 0xFF;
  if (jpeg.length > 18 &&
      jpeg[2] == 0xFF &&
      jpeg[3] == 0xE0 &&
      jpeg[6] == 0x4A &&
      jpeg[7] == 0x46 &&
      jpeg[8] == 0x49 &&
      jpeg[9] == 0x46 &&
      jpeg[10] == 0x00) {
    final out = Uint8List.fromList(jpeg);
    out[13] = 0x01;
    out[14] = hi;
    out[15] = lo;
    out[16] = hi;
    out[17] = lo;
    return out;
  }
  throw StateError('no JFIF APP0 — splice path would be used');
}

Future<void> main(List<String> args) async {
  if (args.isNotEmpty && args[0] == '--stamp') {
    final dir = args[1];
    final src = await File('$dir/pil_q90_420.jpg').readAsBytes();
    await File('$dir/pil_q90_420_stamped.jpg').writeAsBytes(stampDpi(src, 350));
    print('stamped OK');
    return;
  }
  final designPath = args[0];
  final dir = args[1];
  await Directory(dir).create(recursive: true);

  final source = img.decodeImage(await File(designPath).readAsBytes())!;
  print('source ${source.width}x${source.height}');

  // Fit-to-slot dims — same formula as _resizeToFit / native decodeRgbaFile.
  final srcAspect = source.width / source.height;
  final dstAspect = fitW / fitH;
  int newW, newH;
  if (srcAspect > dstAspect) {
    newW = fitW;
    newH = (fitW / srcAspect).round();
  } else {
    newH = fitH;
    newW = (fitH * srcAspect).round();
  }
  print('fitted $newW x $newH');

  final sw = Stopwatch()..start();
  final cubic = img.copyResize(source,
      width: newW, height: newH, interpolation: img.Interpolation.cubic);
  print('cubic upscale ${sw.elapsedMilliseconds}ms');
  sw.reset();
  final linear = img.copyResize(source,
      width: newW, height: newH, interpolation: img.Interpolation.linear);
  print('linear upscale ${sw.elapsedMilliseconds}ms');

  print('PSNR cubic-vs-linear upscale: '
      '${psnr(cubic, linear).toStringAsFixed(2)} dB');

  // OLD final output: Dart encoder on the cubic upscale.
  sw.reset();
  final dartJpg = Uint8List.fromList(
      img.encodeJpg(cubic, quality: 90, chroma: img.JpegChroma.yuv420));
  print('dart encode q90 4:2:0: ${sw.elapsedMilliseconds}ms, '
      '${(dartJpg.length / 1024 / 1024).toStringAsFixed(2)} MB');
  final dartDecoded = img.decodeImage(dartJpg)!;
  print('PSNR old-final vs its raw: '
      '${psnr(cubic, dartDecoded).toStringAsFixed(2)} dB');

  // Hand the NEW path's raw (bilinear upscale) to Pillow/libjpeg-turbo.
  await File('$dir/linear.png').writeAsBytes(img.encodePng(linear));
  await File('$dir/dart_q90_420.jpg').writeAsBytes(dartJpg);
  print('wrote $dir/linear.png');
}
