import 'package:bb_native_codec/bb_native_codec.dart';
import 'package:flutter/services.dart';

import 'collage.dart';

/// Points CollageRenderer's codec hooks at the Android native codec.
/// Idempotent; call once per isolate that renders or preprocesses.
/// collage.dart itself stays Flutter-free so the desktop check tools keep
/// running on the pure-Dart fallback.
///
/// The sheet-sized hand-offs are FILE-based (see collage.dart) — byte
/// payloads that big OOM the Java heap under two concurrent workers.
void installNativeCodecHooks() {
  CollageRenderer.nativeDecodeFromFile = (srcPath, rgbaOutPath, fitW, fitH) =>
      BbNativeCodec.decodeRgbaToFile(
          srcPath: srcPath, outPath: rgbaOutPath, fitW: fitW, fitH: fitH);
  CollageRenderer.nativeEncodeToFile = (w, h, rgbaPath, outPath, q) =>
      BbNativeCodec.encodeRgbaJpegFile(
          width: w,
          height: h,
          rgbaPath: rgbaPath,
          outPath: outPath,
          quality: q);
  CollageRenderer.nativeTranscode = (src, maxW, maxH, q) =>
      BbNativeCodec.transcodeFitJpeg(
          src: src, maxW: maxW, maxH: maxH, quality: q);
}

/// Tiny end-to-end channel check (2x2 encode). True = the native codec is
/// reachable from THIS isolate.
Future<bool> nativeCodecProbe() async {
  final r = await BbNativeCodec.encodeRgbaJpeg(
    width: 2,
    height: 2,
    rgba: Uint8List.fromList(List.filled(16, 255)),
    quality: 90,
  );
  return r != null;
}

/// Body for the per-sheet worker isolates: wires up platform channels
/// (needs the root isolate's [token]) and the native hooks, then renders.
/// If channel setup fails for any reason the hooks stay null and the sheet
/// renders through the pure-Dart path — slower but identical output.
Future<void> renderSheetWorker({
  required List<String> slots,
  required Map<String, String> designPaths,
  required String outPath,
  RootIsolateToken? token,
}) async {
  final sw = Stopwatch()..start();
  var nativeOk = false;
  if (token != null) {
    try {
      BackgroundIsolateBinaryMessenger.ensureInitialized(token);
      nativeOk = await nativeCodecProbe();
      if (nativeOk) installNativeCodecHooks();
    } catch (_) {/* pure-Dart fallback */}
  }
  await CollageRenderer.renderSheetToFile(
    slots: slots,
    designPaths: designPaths,
    outPath: outPath,
  );
  // logcat breadcrumb for adb diagnosis — invisible to the user.
  // ignore: avoid_print
  print('BBCODEC sheet ${outPath.split('/').last} '
      'in ${sw.elapsedMilliseconds}ms native=$nativeOk');
}
