import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';
import 'package:image/image.dart' as img;
import '../models/sheet_plan.dart';

class CollageRenderer {
  /// Native-codec hooks — injected by native_codec_binding.dart wherever
  /// Flutter is available (main isolate, service isolate, sheet workers).
  /// This file deliberately has NO Flutter imports so the desktop check
  /// tools (`dart run tool/check_dpi.dart` etc.) still run: with the hooks
  /// null everything falls back to the pure-Dart image-package path,
  /// producing identical output — the native path is ONLY faster.
  /// FILE-based, not byte-based: the 106 MB sheet canvas through the
  /// method channel doubles up on the Java heap and OOMs with two workers
  /// (probe passed, real payload failed silently — the "native but still
  /// 85 s/sheet" trap). Files keep the pixels in native memory on the
  /// Kotlin side.
  /// fitW/fitH: the native side also scales (up or down, aspect kept) to
  /// fit that box — the pure-Dart cubic upscale of every 1800x2700 design
  /// to slot size took ~20 s per design and was the hidden sheet killer.
  static Future<({int width, int height})?> Function(
      String srcPath, String rgbaOutPath, int fitW, int fitH)?
      nativeDecodeFromFile;
  static Future<int?> Function(int width, int height, String rgbaPath,
      String outPath, int quality)? nativeEncodeToFile;
  static Future<Uint8List?> Function(
      Uint8List src, int maxW, int maxH, int quality)? nativeTranscode;

  /// 350 DPI — the print shop's standard. Sheet = 4200×6300 px,
  /// each 6x9 slot = 2100×3150 px.
  static const int dpi = 350;
  static const double sheetWidthInches = 12.0;
  static const double sheetHeightInches = 18.0;
  static const double slotWidthInches = 6.0;
  static const double slotHeightInches = 9.0;

  static const int gutterPx = 12;
  static const int cutLineThicknessPx = 4;
  static const int _cutLineColor = 0xFF606060;

  static int get sheetWidthPx => (sheetWidthInches * dpi).round();
  static int get sheetHeightPx => (sheetHeightInches * dpi).round();
  static int get slotWidthPx => (slotWidthInches * dpi).round();
  static int get slotHeightPx => (slotHeightInches * dpi).round();

  /// Usable area inside one slot after the cut gutter is reserved. Same
  /// for all four slots (the gutter is split between the two halves).
  static int get innerSlotWidthPx => slotWidthPx - gutterPx ~/ 2;
  static int get innerSlotHeightPx => slotHeightPx - gutterPx ~/ 2;

  static int get _verticalCutCenterX => sheetWidthPx ~/ 2;
  static int get _horizontalCutCenterY => sheetHeightPx ~/ 2;

  /// Max output size per collage. User wants the sharpest possible print
  /// at 300 DPI but capped so a multi-sheet email doesn't balloon.
  static const int maxBytesPerSheet = 6 * 1024 * 1024;

  /// Native-first version of [preprocessDesign]: same guard rails, same
  /// keep-as-is shortcut, but the decode+downscale+re-encode runs on
  /// Android's codec (a second instead of several). Falls back to the
  /// pure-Dart path in a worker-style call when the native hook is absent
  /// or fails. Callers on the service isolate use THIS.
  static Future<Uint8List> preprocessDesignFast(Uint8List original) async {
    if (original.length > 64 * 1024 * 1024) {
      throw StateError(
          'Design file too large (${original.length ~/ (1024 * 1024)} MB, max 64 MB)');
    }
    final headerInfo = img.findDecoderForData(original)?.startDecode(original);
    if (headerInfo != null &&
        headerInfo.width * headerInfo.height > 80 * 1000 * 1000) {
      throw StateError(
          'Design dimensions too large (${headerInfo.width}x${headerInfo.height}, max 80 MP)');
    }
    if (headerInfo != null &&
        headerInfo.width <= innerSlotWidthPx &&
        headerInfo.height <= innerSlotHeightPx) {
      return original; // already slot-sized — keep untouched, no quality loss
    }
    final native = await nativeTranscode?.call(
        original, innerSlotWidthPx, innerSlotHeightPx, 95);
    if (native != null && native.isNotEmpty) return native;
    // Pure-Dart fallback runs in a short-lived worker so the calling
    // (service) isolate stays responsive to cancel/mute messages.
    return Isolate.run(() => preprocessDesign(original));
  }

  /// Downscale + re-encode a source design so it exactly fits one slot.
  /// Run ONCE per design when it's downloaded (instead of decoding the
  /// full-resolution original again for every sheet it appears on) —
  /// this is what keeps memory flat on 30-40 design orders.
  static Uint8List preprocessDesign(Uint8List original) {
    // Guard rails BEFORE the expensive full decode: a single absurd file
    // (a 100 MB scan or a 15000x20000 pixel poster dropped into the
    // OneDrive folder) must fail with a clear error, not OOM-kill the app.
    if (original.length > 64 * 1024 * 1024) {
      throw StateError(
          'Design file too large (${original.length ~/ (1024 * 1024)} MB, max 64 MB)');
    }
    final headerInfo = img.findDecoderForData(original)?.startDecode(original);
    if (headerInfo != null &&
        headerInfo.width * headerInfo.height > 80 * 1000 * 1000) {
      throw StateError(
          'Design dimensions too large (${headerInfo.width}x${headerInfo.height}, max 80 MP)');
    }
    final source = img.decodeImage(original);
    if (source == null) {
      throw StateError('Could not decode design image');
    }
    // Already slot-sized or smaller → keep as-is (no quality loss).
    if (source.width <= innerSlotWidthPx && source.height <= innerSlotHeightPx) {
      return original;
    }
    final fitted = _resizeToFit(source, innerSlotWidthPx, innerSlotHeightPx);
    return Uint8List.fromList(img.encodeJpg(fitted, quality: 95));
  }

  /// Renders one sheet start-to-finish inside a caller-provided worker
  /// isolate: reads the slot-sized design files, composites, encodes,
  /// stamps the DPI tag, and writes the JPEG via tmp+rename. Designed to
  /// be the body of an `Isolate.run` call — every argument is a plain
  /// sendable value, and all memory is freed when the worker exits.
  static Future<void> renderSheetToFile({
    required List<String> slots,
    required Map<String, String> designPaths,
    required String outPath,
  }) async {
    for (final id in slots.toSet()) {
      if (designPaths[id] == null) {
        throw StateError('No cached file for design "$id"');
      }
    }
    Uint8List? bytes;
    if (nativeDecodeFromFile != null && nativeEncodeToFile != null) {
      // Fast lane: Android codec end-to-end via scratch files.
      bytes = await _renderViaNativeFiles(
        slots: slots,
        designPaths: designPaths,
        scratchPrefix: outPath,
      );
    } else {
      // ignore: avoid_print
      print('BBCODEC nf skipped: hooks absent');
    }
    if (bytes == null) {
      // Pure-Dart lane (desktop tools / native hiccup) — identical output.
      final designImages = <String, Uint8List>{};
      for (final id in slots.toSet()) {
        designImages[id] = await File(designPaths[id]!).readAsBytes();
      }
      bytes = await render(
        plan: SheetPlan(slots: slots, copies: 1),
        designImages: designImages,
      );
    }
    final tmp = File('$outPath.tmp');
    // Self-heal: recreate the checkpoint dir if anything removed it while
    // we were rendering — a missing parent must not kill the order.
    await tmp.parent.create(recursive: true);
    await tmp.writeAsBytes(bytes);
    await tmp.rename(outPath);
  }

  /// Sheet render with EVERY pixel-heavy step on the native codec, all
  /// hand-offs via scratch files next to [scratchPrefix]. Returns null on
  /// any codec failure — the caller falls back to the pure-Dart lane.
  static Future<Uint8List?> _renderViaNativeFiles({
    required List<String> slots,
    required Map<String, String> designPaths,
    required String scratchPrefix,
  }) async {
    final scratch = <String>[];
    final sw = Stopwatch()..start();
    // Stage-timing breadcrumbs (logcat via adb) — cheap, always on.
    void mark(String stage) {
      // ignore: avoid_print
      print('BBCODEC nf $stage +${sw.elapsedMilliseconds}ms');
    }

    try {
      await File(scratchPrefix).parent.create(recursive: true);
      final canvas = _canvasReuse ??= img.Image(
        width: sheetWidthPx,
        height: sheetHeightPx,
        numChannels: 4,
      );
      final canvasBytes = canvas.toUint8List();
      canvasBytes.fillRange(0, canvasBytes.length, 255);
      final innerW = innerSlotWidthPx;
      final innerH = innerSlotHeightPx;

      var scratchN = 0;
      for (final designId in slots.toSet()) {
        final rgbaTmp = '$scratchPrefix.d${scratchN++}.rgba';
        scratch.add(rgbaTmp);
        // Decode AND fit-scale natively — the RGBA that comes back is
        // already slot-sized, so no Dart resize ever runs in this lane.
        final dims = await nativeDecodeFromFile!(
            designPaths[designId]!, rgbaTmp, innerW, innerH);
        if (dims == null) {
          mark('FAIL decode $designId');
          return null;
        }
        if (dims.width > innerW || dims.height > innerH) {
          mark('FAIL fit $designId ${dims.width}x${dims.height}');
          return null;
        }
        final rgba = await File(rgbaTmp).readAsBytes();
        final fitted = img.Image.fromBytes(
          width: dims.width,
          height: dims.height,
          bytes: rgba.buffer,
          numChannels: 4,
          order: img.ChannelOrder.rgba,
        );
        final fittedBytes = fitted.toUint8List();
        final fittedStride = fitted.rowStride;
        for (var i = 0; i < slots.length; i++) {
          if (slots[i] != designId) continue;
          final col = i % 2;
          final row = i ~/ 2;
          final slotLeft = col * slotWidthPx + (col == 1 ? gutterPx ~/ 2 : 0);
          final slotTop = row * slotHeightPx + (row == 1 ? gutterPx ~/ 2 : 0);
          final x = slotLeft + (innerW - fitted.width) ~/ 2;
          final y = slotTop + (innerH - fitted.height) ~/ 2;
          final dstStride = canvas.rowStride;
          for (var r = 0; r < fitted.height; r++) {
            final dstOff = (y + r) * dstStride + x * 4;
            final srcOff = r * fittedStride;
            canvasBytes.setRange(
                dstOff, dstOff + fitted.width * 4, fittedBytes, srcOff);
          }
        }
      }

      _drawCutLines(canvas);
      mark('decode+blit done');

      final rgbaPath = '$scratchPrefix.canvas.rgba';
      final jpgPath = '$scratchPrefix.native.jpg';
      scratch..add(rgbaPath)..add(jpgPath);
      await File(rgbaPath).writeAsBytes(canvasBytes);
      mark('rgba written');
      for (final quality in const [90, 85, 75]) {
        final size = await nativeEncodeToFile!(
            canvas.width, canvas.height, rgbaPath, jpgPath, quality);
        mark('encode q$quality size=$size');
        if (size == null || size <= 0) {
          mark('FAIL encode q$quality');
          return null;
        }
        if (size <= maxBytesPerSheet || quality == 75) {
          final jpeg = await File(jpgPath).readAsBytes();
          mark('done');
          return _stampDpi(jpeg, dpi);
        }
      }
      return null; // unreachable — 75 always returns above
    } catch (e) {
      mark('EXC $e');
      return null; // any surprise -> pure-Dart lane
    } finally {
      for (final p in scratch) {
        try {
          await File(p).delete();
        } catch (_) {/* already gone */}
      }
    }
  }

  /// The 79 MB sheet canvas is allocated ONCE per isolate and reused for
  /// every sheet. In the worker-isolate model each worker renders exactly
  /// one sheet, so this is simply that worker's single allocation — freed
  /// in full when the worker exits.
  static img.Image? _canvasReuse;

  static Future<Uint8List> render({
    required SheetPlan plan,
    required Map<String, Uint8List> designImages,
  }) async {
    // RGBA (not RGB): Android's Bitmap wants RGBA buffers, so keeping the
    // canvas in that layout lets the native encoder swallow it with zero
    // per-pixel conversion anywhere. The Dart fallback encoder handles
    // 4-channel images fine (alpha is simply dropped by JPEG).
    final canvas = _canvasReuse ??= img.Image(
      width: sheetWidthPx,
      height: sheetHeightPx,
      numChannels: 4,
    );
    // Fast white fill: one bulk fillRange over the raw buffer instead of
    // img.fill's 26-million per-pixel calls (seconds on a phone). 255
    // everywhere = white with full alpha.
    final canvasBytes = canvas.toUint8List();
    canvasBytes.fillRange(0, canvasBytes.length, 255);

    final innerW = innerSlotWidthPx;
    final innerH = innerSlotHeightPx;

    // Composite ONE design at a time: decode → fit → paint every slot the
    // design occupies → release, before touching the next design. Peak
    // memory is canvas + one decoded design (~100 MB), instead of canvas
    // + all four fitted designs (~160+ MB).
    for (final designId in plan.slots.toSet()) {
      final bytes = designImages[designId];
      if (bytes == null) {
        throw StateError('Missing image for design "$designId"');
      }
      var source = img.decodeImage(bytes);
      if (source == null) {
        throw StateError('Could not decode image for "$designId"');
      }
      // Blitting assumes matching rgba8888 layout — normalize when a
      // source decodes to something else (16-bit, palette, 3-channel…).
      if (source.numChannels != 4 || source.format != img.Format.uint8) {
        source = source.convert(numChannels: 4, format: img.Format.uint8);
      }
      final fitted = _resizeToFit(source, innerW, innerH);
      final fittedBytes = fitted.toUint8List();
      final fittedStride = fitted.rowStride;

      for (var i = 0; i < plan.slots.length; i++) {
        if (plan.slots[i] != designId) continue;

        final col = i % 2;
        final row = i ~/ 2;

        final slotLeft = col * slotWidthPx + (col == 1 ? gutterPx ~/ 2 : 0);
        final slotTop = row * slotHeightPx + (row == 1 ? gutterPx ~/ 2 : 0);

        final x = slotLeft + (innerW - fitted.width) ~/ 2;
        final y = slotTop + (innerH - fitted.height) ~/ 2;

        // Row-blit instead of img.compositeImage: both buffers are plain
        // rgba8888, so each row is a single memcpy. compositeImage's
        // per-pixel path took ~30-60 s per sheet on a phone; this takes
        // milliseconds.
        final dstStride = canvas.rowStride;
        for (var r = 0; r < fitted.height; r++) {
          final dstOff = (y + r) * dstStride + x * 4;
          final srcOff = r * fittedStride;
          canvasBytes.setRange(
              dstOff, dstOff + fitted.width * 4, fittedBytes, srcOff);
        }
      }
    }

    _drawCutLines(canvas);

    // Adaptive JPEG quality ladder: highest print-transparent setting
    // first, stepping down only if the result blows past
    // [maxBytesPerSheet]. Quality 90 is indistinguishable from 95 on a
    // 350 DPI print; 75 is the floor — visible artifacts appear below.
    //
    // chroma 4:2:0: the encoder's 4:4:4 default is the slowest possible
    // mode and wasted — the source photos are camera JPEGs that are
    // already 4:2:0, so there is no extra chroma detail to preserve.
    // 4:2:0 cuts encode time ~35% and file size ~30%. Encode is the
    // longest single-threaded step of the render, so this matters.
    Uint8List? bytes;
    for (final quality in const [90, 85, 75]) {
      bytes = Uint8List.fromList(img.encodeJpg(canvas,
          quality: quality, chroma: img.JpegChroma.yuv420));
      if (bytes.length <= maxBytesPerSheet) break;
    }
    // Stamp the real DPI into the JFIF header. Without this the JPEG
    // carries no density info and Photoshop defaults to 72 ppi, showing a
    // bogus 50"x75" document size — print shops reject that. Applies to
    // the native encoder's output the same way (it patches an existing
    // JFIF APP0 or splices one in).
    return _stampDpi(bytes!, dpi);
  }

  /// Writes [dpiValue] into the JPEG's JFIF APP0 density fields so photo
  /// software reports the correct print resolution / document size.
  /// If the encoder didn't emit a JFIF APP0 segment, one is inserted
  /// right after the SOI marker.
  static Uint8List _stampDpi(Uint8List jpeg, int dpiValue) {
    if (jpeg.length < 4 || jpeg[0] != 0xFF || jpeg[1] != 0xD8) {
      return jpeg; // not a JPEG — leave untouched
    }
    final hi = (dpiValue >> 8) & 0xFF;
    final lo = dpiValue & 0xFF;
    // Common case: encoder wrote APP0/JFIF immediately after SOI.
    if (jpeg.length > 18 &&
        jpeg[2] == 0xFF &&
        jpeg[3] == 0xE0 &&
        jpeg[6] == 0x4A && // 'J'
        jpeg[7] == 0x46 && // 'F'
        jpeg[8] == 0x49 && // 'I'
        jpeg[9] == 0x46 && // 'F'
        jpeg[10] == 0x00) {
      final out = Uint8List.fromList(jpeg);
      out[13] = 0x01; // density units: 1 = dots per inch
      out[14] = hi; // X density
      out[15] = lo;
      out[16] = hi; // Y density
      out[17] = lo;
      return out;
    }
    // No JFIF segment — splice a minimal APP0 in after SOI.
    final app0 = <int>[
      0xFF, 0xE0, 0x00, 0x10, // APP0, length 16
      0x4A, 0x46, 0x49, 0x46, 0x00, // "JFIF\0"
      0x01, 0x01, // version 1.1
      0x01, // units: dpi
      hi, lo, // X density
      hi, lo, // Y density
      0x00, 0x00, // no thumbnail
    ];
    final out = Uint8List(jpeg.length + app0.length);
    out[0] = 0xFF;
    out[1] = 0xD8;
    out.setRange(2, 2 + app0.length, app0);
    out.setRange(2 + app0.length, out.length, jpeg, 2);
    return out;
  }

  static void _drawCutLines(img.Image canvas) {
    final color = img.ColorRgb8(
      (_cutLineColor >> 16) & 0xFF,
      (_cutLineColor >> 8) & 0xFF,
      _cutLineColor & 0xFF,
    );
    final half = cutLineThicknessPx ~/ 2;

    img.fillRect(
      canvas,
      x1: _verticalCutCenterX - half,
      y1: 0,
      x2: _verticalCutCenterX + (cutLineThicknessPx - half) - 1,
      y2: sheetHeightPx - 1,
      color: color,
    );

    img.fillRect(
      canvas,
      x1: 0,
      y1: _horizontalCutCenterY - half,
      x2: sheetWidthPx - 1,
      y2: _horizontalCutCenterY + (cutLineThicknessPx - half) - 1,
      color: color,
    );
  }

  static img.Image _resizeToFit(img.Image src, int targetW, int targetH) {
    final srcAspect = src.width / src.height;
    final dstAspect = targetW / targetH;
    int newW, newH;
    if (srcAspect > dstAspect) {
      newW = targetW;
      newH = (targetW / srcAspect).round();
    } else {
      newH = targetH;
      newW = (targetH * srcAspect).round();
    }
    // Preprocessed designs are already slot-sized — skip the copy entirely.
    if (newW == src.width && newH == src.height) return src;
    // Pick the interpolation strategy that matches the resize direction:
    //   * downscale → `average` for crisp text/lines without aliasing.
    //     Linear was producing slightly soft edges.
    //   * upscale → `cubic` preserves more apparent sharpness than linear.
    final isDownscale = newW < src.width || newH < src.height;
    final interp = isDownscale
        ? img.Interpolation.average
        : img.Interpolation.cubic;
    return img.copyResize(src, width: newW, height: newH, interpolation: interp);
  }
}
