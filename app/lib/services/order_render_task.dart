import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:archive/archive_io.dart';
import 'package:flutter/services.dart' show RootIsolateToken;
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:flutter_ringtone_player/flutter_ringtone_player.dart';
import 'package:flutter_volume_controller/flutter_volume_controller.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/sheet_plan.dart';
import 'collage.dart';
import 'design_library.dart';
import 'gdrive_uploader.dart';
import 'native_codec_binding.dart';
import 'onedrive_auth.dart';
import 'onedrive_client.dart';
import 'settings_store.dart';

/// Constants shared between the UI and the background isolate.
class OrderRenderConstants {
  /// SharedPreferences key — UI writes the pending order JSON, background
  /// reads it on start.
  static const String pendingOrderPrefKey = 'pending_order_json';

  /// SharedPreferences key — UI writes the full serialized [PackingResult]
  /// so that if the activity is killed mid-render we can rebuild the
  /// preview screen from disk and rejoin the running service.
  static const String activeOrderResultPrefKey = 'active_order_result_json';

  /// SharedPreferences key — background writes a JSON blob describing
  /// the completed render (zip + per-sheet file paths).
  static const String lastRenderPrefKey = 'last_render_meta';

  /// Notification channel id. Bumped to v2 because Android caches channel
  /// settings (importance, sound) per channel id — bumping forces a
  /// fresh channel with the new LOW importance so render progress
  /// actually shows in the status bar.
  static const String notificationChannelId = 'order_render_channel_v2';
  static const String notificationChannelName = 'Print Collage Tool';

  /// Action key sent from the UI via [FlutterForegroundTask.sendDataToTask]
  /// to wake the handler immediately to render a queued order (vs waiting
  /// for the next periodic tick).
  static const String actionKey = 'action';
  static const String actionRender = 'render';

  /// UI tells the background isolate to stop the "order ready" ringtone
  /// — fired whenever the user brings the app back to foreground.
  static const String actionMute = 'mute_alarm';

  /// Fires the real order-ready ringtone path on demand (long-press the
  /// "New Order" title). Lets the user — and adb-driven checks — verify
  /// the full-volume ring without rendering an actual order.
  static const String actionTestRing = 'test_ring';

  /// Download every not-yet-cached design in the OneDrive folder into the
  /// slot-sized design cache. Sent by the UI after a manual refresh; also
  /// runs automatically after each scheduled sync.
  static const String actionPrefetch = 'prefetch_designs';

  /// UI tells the background isolate to abandon the in-flight render
  /// (user tapped Edit or Cancel). The pipeline aborts at the next safe
  /// checkpoint without writing an error result.
  static const String actionCancel = 'cancel_render';
}

/// Top-level entry point Flutter calls in the background isolate when
/// the foreground service starts. Must be top-level / static and marked
/// with the vm:entry-point pragma so tree-shaking doesn't drop it.
@pragma('vm:entry-point')
void orderRenderTaskEntryPoint() {
  FlutterForegroundTask.setTaskHandler(BackgroundTaskHandler());
}

/// Unified background task handler:
///
/// * Periodically (every onRepeatEvent tick) refreshes the OneDrive design
///   list so the on-disk cache stays current even while the user has the
///   app closed.
/// * When the UI sends an `action: render` payload, runs the order
///   download/render/zip pipeline and writes the result for the UI to
///   pick up.
///
/// One persistent foreground service handles both — the package only
/// allows one service per app, so we multiplex.
class BackgroundTaskHandler extends TaskHandler {
  bool _rendering = false;
  bool _syncing = false;
  bool _cancelRequested = false;
  int? _lastSyncHour;
  DateTime? _lastSyncDay;

  /// Abort the pipeline at the next loop boundary after the user cancels.
  void _checkCancelled() {
    if (_cancelRequested) {
      throw StateError('Render cancelled by user');
    }
  }

  /// Sync only at these hours of the day (24h clock). Every 3 hours within
  /// the 10:00–20:00 business window: 10am, 1pm, 4pm, 7pm.
  static const Set<int> _syncHours = {10, 13, 16, 19};

  @override
  Future<void> onStart(DateTime timestamp, TaskStarter starter) async {
    // Route image decode/encode through Android's native codec (with
    // automatic pure-Dart fallback) — this is where the render speed
    // comes from. The probe prints to logcat so a slow phone can be
    // diagnosed over adb without touching the UI.
    try {
      installNativeCodecHooks();
      final ok = await nativeCodecProbe();
      // ignore: avoid_print
      print('BBCODEC service probe: native=$ok '
          'token=${RootIsolateToken.instance != null}');
    } catch (e) {
      // ignore: avoid_print
      print('BBCODEC service probe error: $e');
    }
    // Crash recovery: if the process died mid-render (low memory, reboot),
    // the pending order is still in prefs and the per-sheet checkpoints
    // are on disk. Resume automatically — the user shouldn't have to
    // reopen the app to get their order finished.
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.reload();
      final pending =
          prefs.getString(OrderRenderConstants.pendingOrderPrefKey) ?? '';
      final done =
          prefs.getString(OrderRenderConstants.lastRenderPrefKey) ?? '';
      if (pending.isNotEmpty && done.isEmpty) {
        await _tryRender();
        return;
      }
    } catch (_) {/* fall through to sync */}

    // Sync silently if we're inside a sync window. No notification chatter
    // about "Next sync at HH:00" — the user only wants the render-time
    // progress and the final "Order ready" notification visible.
    if (_isInSyncWindow(DateTime.now())) {
      await _trySync(); // ends with its own prefetch pass
    } else {
      // Service restarted (reboot, ColorOS kill) with a possibly
      // half-finished design download — quietly pick it up again.
      // No-ops in seconds when the cache is already complete.
      await _prefetchDesigns();
    }
  }

  @override
  void onRepeatEvent(DateTime timestamp) {
    final now = DateTime.now();
    if (_isInSyncWindow(now) && !_alreadySyncedThisSlot(now)) {
      _trySync();
    }
  }

  bool _isInSyncWindow(DateTime now) => _syncHours.contains(now.hour);

  bool _alreadySyncedThisSlot(DateTime now) {
    if (_lastSyncHour == null || _lastSyncDay == null) return false;
    final today = DateTime(now.year, now.month, now.day);
    return _lastSyncDay == today && _lastSyncHour == now.hour;
  }


  @override
  void onReceiveData(Object data) {
    if (data is! Map) return;
    final action = data[OrderRenderConstants.actionKey];
    if (action == OrderRenderConstants.actionRender) {
      _tryRender();
    } else if (action == OrderRenderConstants.actionMute) {
      _stopAlarm();
    } else if (action == OrderRenderConstants.actionTestRing) {
      _startAlarm();
    } else if (action == OrderRenderConstants.actionPrefetch) {
      // User-initiated (refresh button) — don't gate on WiFi.
      if (_prefetching) {
        // Mid-run press: queue ONE fresh pass for right after this one —
        // it re-lists the folder, so designs added a minute ago are seen.
        _prefetchQueued = true;
      } else {
        _prefetchDesigns();
      }
    } else if (action == OrderRenderConstants.actionCancel) {
      if (_rendering) {
        _cancelRequested = true;
      } else {
        _resetNotifToIdle();
      }
    }
  }

  /// Looping ringtone that fires when an order render finishes, so the
  /// user notices even with the phone in their pocket. Stops on the first
  /// `actionMute` from the UI (which is sent on app resume).
  ///
  /// Plays through the ALARM audio stream (asAlarm) — silent/vibrate mode
  /// does not touch that stream — and force-raises the alarm stream volume
  /// to maximum first, so the ring is at full blast even if the user had
  /// alarm volume turned down.
  Future<void> _startAlarm() async {
    // Each step in its OWN try/catch: a failure of the cosmetic
    // hide-volume-UI call must not skip the volume raise, and a volume
    // failure must not skip the ring itself.
    try {
      await FlutterVolumeController.updateShowSystemUI(false);
    } catch (_) {/* cosmetic only */}
    try {
      await FlutterVolumeController.setVolume(1.0, stream: AudioStream.alarm);
    } catch (_) {/* volume plugin hiccup — still ring at current volume */}
    // Await the platform call so a channel error is actually caught here
    // (fire-and-forget silently swallowed failures), and retry — this is
    // the one step that must not fail quietly.
    for (var attempt = 0; attempt < 3; attempt++) {
      try {
        await FlutterRingtonePlayer().play(
          android: AndroidSounds.ringtone,
          ios: IosSounds.glass,
          looping: true,
          volume: 1.0,
          asAlarm: true,
        );
        return;
      } catch (_) {
        await Future<void>.delayed(const Duration(seconds: 1));
      }
    }
  }

  Future<void> _stopAlarm() async {
    try {
      FlutterRingtonePlayer().stop();
    } catch (_) {/* swallow */}
    // Clear the lingering "Order ready" text — but never clobber the live
    // progress notification of a render that's still running (the UI sends
    // mute on every app-resume, including mid-render).
    if (!_rendering) {
      _resetNotifToIdle();
    }
  }

  @override
  Future<void> onDestroy(DateTime timestamp) async {}

  // ============================================================
  // Periodic sync — keeps designs_cache.json fresh
  // ============================================================
  Future<void> _trySync() async {
    if (_rendering || _syncing) return; // never overlap with active work
    _syncing = true;
    try {
      final settings = await AppSettings.load();
      final folder = settings.oneDriveFolder;
      if (folder.isEmpty) return; // silent — no notif chatter
      final auth = OneDriveAuth();
      if (!await auth.isSignedIn) return;
      final library = DesignLibrary(auth);
      await library.refresh(folder);
      final now = DateTime.now();
      _lastSyncHour = now.hour;
      _lastSyncDay = DateTime(now.year, now.month, now.day);
      // Intentionally don't update notification — user wants the
      // foreground icon quiet during sync.
    } catch (_) {
      // Quiet failure — user explicitly does not want sync notifications.
    } finally {
      _syncing = false;
    }
    // Keep the design cache complete, so orders skip the download phase.
    // WiFi-gated: a scheduled slot must never eat mobile data.
    await _prefetchDesigns();
  }

  bool _prefetching = false;

  /// Short-lived folder-listing cache. The prefetch re-lists the folder on
  /// every pass (constantly, since downloads never stop), so an order can
  /// reuse that listing and skip its own "Loading OneDrive" wait entirely.
  /// TTL keeps cTag staleness bounded to a couple of minutes.
  List<OneDriveFile>? _listingCache;
  String? _listingFolder;
  DateTime? _listingAt;

  Future<List<OneDriveFile>> _listDesigns(
    OneDriveClient client,
    String folder, {
    bool forceFresh = false,
  }) async {
    final cache = _listingCache;
    // 90 s TTL: long enough that back-to-back orders skip the listing
    // (prefetch refreshes it after every render), short enough that a
    // just-replaced picture (new cTag) is picked up almost immediately.
    if (!forceFresh &&
        cache != null &&
        _listingFolder == folder &&
        _listingAt != null &&
        DateTime.now().difference(_listingAt!) < const Duration(seconds: 90)) {
      return cache;
    }
    final files = await client.listFolderByPath(folder);
    _listingCache = files;
    _listingFolder = folder;
    _listingAt = DateTime.now();
    return files;
  }

  /// Downloads every design in the OneDrive folder that isn't already in
  /// the slot-sized design cache (new design number OR same number with a
  /// changed picture — the cTag in the filename catches both), so orders
  /// skip "Preparing designs" entirely and work offline.
  ///
  /// Completely silent on the notification bar (sync-quiet law); in-app
  /// progress is sent as phase 'prefetch' task-data. Stops the moment a
  /// render starts — the pipeline fetches what it needs itself, and the
  /// distinct '.pf.tmp' suffix means a half-written prefetch file can
  /// never collide with the pipeline's own '.tmp' write of the same
  /// design.
  Future<void> _prefetchDesigns() async {
    // Runs happily ALONGSIDE a render (user requirement: downloading must
    // never stop). File safety: distinct '.pf.tmp' suffix, atomic renames,
    // per-item existence re-check, and stale-version sweep only AFTER the
    // new file is in place — so the pipeline can never see a missing file.
    if (_prefetching) return;
    _prefetching = true;
    try {
      final settings = await AppSettings.load();
      final folder = settings.oneDriveFolder;
      if (folder.isEmpty) return;
      final auth = OneDriveAuth();
      if (!await auth.isSignedIn) return;
      final client = OneDriveClient(auth);
      // Always fresh here — this is what keeps the shared cache warm.
      final files = await _listDesigns(client, folder, forceFresh: true);
      final docs = await getApplicationDocumentsDirectory();
      final cacheDir = Directory('${docs.path}/design_cache');
      await cacheDir.create(recursive: true);

      String sanitize(String s) => s.replaceAll(RegExp(r'[^a-zA-Z0-9]'), '_');
      // Current cache size — prefetch must respect the same 20 GB cap the
      // post-order LRU prune enforces, or a huge folder would fill the phone.
      var cacheBytes = 0;
      await for (final e in cacheDir.list()) {
        if (e is File && e.path.endsWith('.jpg')) {
          cacheBytes += (await e.stat()).size;
        }
      }
      const maxCacheBytes = 20 * 1024 * 1024 * 1024;

      final todo = <OneDriveFile>[];
      for (final f in files) {
        final safe = sanitize(f.nameWithoutExtension);
        final ctag = sanitize(f.cTag ?? 'v0');
        if (!await File('${cacheDir.path}/$safe@$ctag.jpg').exists()) {
          todo.add(f);
        }
      }
      if (todo.isEmpty) return;
      _prefetchAnnounced = true;
      // Progress counts against the WHOLE folder, with already-cached
      // designs included — so after an interruption (order rendered
      // mid-download, app restart) the bar resumes at 29/1540, not 0/1511.
      final alreadyCached = files.length - todo.length;

      // 20 downloads in flight at once (user's explicit choice) — the pool
      // is network-bound, so this saturates whatever connection the phone
      // has. If OneDrive throttles with 429s, the client's retry/backoff
      // absorbs it. Single-isolate event loop, so the shared counters need
      // no locks; preprocess runs off-thread on the native codec.
      const parallel = 20;
      var nextIdx = 0;
      var doneCount = 0;
      Future<void> pump() async {
        while (true) {
          if (cacheBytes > maxCacheBytes) return; // cap — LRU prune rules
          if (nextIdx >= todo.length) return;
          final f = todo[nextIdx++];
          final id = f.nameWithoutExtension;
          final safe = sanitize(id);
          final path =
              '${cacheDir.path}/$safe@${sanitize(f.cTag ?? 'v0')}.jpg';
          try {
            // Re-check right before working: a concurrent render's phase
            // 1b may have cached this design since todo was built.
            if (!await File(path).exists()) {
              final original = await client.downloadFile(f.id);
              // Native codec (fast, off-thread); falls back internally to
              // a pure-Dart pass if the native path is unavailable.
              final slotSized =
                  await CollageRenderer.preprocessDesignFast(original);
              // Atomic rename FIRST (overwrites in place — a reader can
              // never see a gap), THEN sweep older-cTag leftovers.
              final tmp = File('$path.pf.tmp');
              await tmp.writeAsBytes(slotSized);
              await tmp.rename(path);
              cacheBytes += slotSized.length;
              final newName = path.split('/').last;
              try {
                await for (final old in cacheDir.list()) {
                  if (old is File) {
                    final name = old.uri.pathSegments.last;
                    if (name.startsWith('$safe@') && name != newName) {
                      try {
                        await old.delete();
                      } catch (_) {/* harmless */}
                    }
                  }
                }
              } catch (_) {/* best-effort */}
            }
          } catch (_) {
            // One bad/huge/unreachable design must not stop the rest.
          }
          doneCount++;
          _send({
            'phase': 'prefetch',
            'current': alreadyCached + doneCount,
            'total': files.length,
            'label': id,
          });
        }
      }

      await Future.wait(List.generate(parallel, (_) => pump()));
    } catch (_) {
      // Silent by law — no sync noise.
    } finally {
      // Always close the in-app banner, even on early exit (render
      // started, cache cap reached, network died mid-way).
      if (_prefetchAnnounced) {
        _prefetchAnnounced = false;
        _send({'phase': 'prefetch', 'current': 1, 'total': 1});
      }
      _prefetching = false;
      if (_prefetchQueued) {
        _prefetchQueued = false;
        // One queued re-check (user pressed refresh mid-run).
        _prefetchDesigns();
      }
    }
  }

  bool _prefetchAnnounced = false;
  bool _prefetchQueued = false;

  /// Reset the persistent foreground-service notification to its minimal
  /// idle state. Called when the render result has been consumed (the UI
  /// sends actionMute on app resume) so the post-render "Order ready"
  /// text doesn't linger.
  void _resetNotifToIdle() {
    FlutterForegroundTask.updateService(
      notificationTitle: 'Print Collage Tool',
      notificationText: '',
    );
  }

  /// Set when a render request arrives while another render is still
  /// unwinding (e.g. the user tapped Edit → cancel → retyped → Continue
  /// before the old pipeline reached a cancellation checkpoint). The
  /// queued request runs as soon as the current one exits — without this
  /// the new order's request was silently dropped and the UI spinner
  /// hung forever.
  bool _renderQueued = false;

  // ============================================================
  // On-demand order render — triggered by UI's sendDataToTask
  // ============================================================
  Future<void> _tryRender() async {
    if (_rendering) {
      _renderQueued = true;
      return;
    }
    _rendering = true;
    try {
      do {
        _renderQueued = false;
        try {
          await _runPipeline();
        } catch (e, st) {
          if (_cancelRequested) {
            // User cancelled (Edit / Cancel order) — quiet exit, no error
            // notification, no failure metadata.
            _resetNotifToIdle();
          } else {
            // Reporting the failure must never itself abort the queue loop
            // (a prefs write can fail) — a queued next order has to run.
            try {
              await _sendError('$e\n$st');
            } catch (_) {/* best-effort */}
          }
        }
        _cancelRequested = false;
      } while (_renderQueued);
    } finally {
      _rendering = false;
      _renderQueued = false;
      // Don't stomp on "Order ready" — only revert to the idle banner if
      // the render did NOT just complete successfully. The pipeline sets
      // its own "Order ready" notification before returning.
    }
    // A render interrupts any in-flight prefetch (it checks _rendering per
    // file). Now that the order is done, pick the download back up where
    // it left off — already-cached files are skipped, so the progress
    // numbers simply continue.
    _prefetchDesigns();
  }

  Future<void> _runPipeline() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.reload();
    final pendingJson = prefs.getString(OrderRenderConstants.pendingOrderPrefKey);
    if (pendingJson == null || pendingJson.isEmpty) {
      // A render request arrived but the order was already wiped (cancel
      // race) or consumed. Nothing to do — quietly return, do NOT write an
      // error blob that would greet the user as a failure. Only reset the
      // notification when there's no fresh result either — a redundant
      // queued request right after completion must not clobber the
      // "Order ready" text.
      final done = prefs.getString(OrderRenderConstants.lastRenderPrefKey) ?? '';
      if (done.isEmpty) {
        _resetNotifToIdle();
      }
      return;
    }
    final pending = jsonDecode(pendingJson) as Map<String, dynamic>;
    final folder = pending['folder'] as String;
    final sheets = (pending['sheets'] as List).cast<Map<String, dynamic>>().map((s) {
      return SheetPlan(
        slots: (s['slots'] as List).cast<String>(),
        copies: s['copies'] as int,
      );
    }).toList();
    final totalSheetsToPrint = pending['totalSheetsToPrint'] as int;
    // Per-order nonce isolates this order's checkpoint files. Without it,
    // sheet_0.jpg left behind by a cancelled order could be mistaken for
    // the new order's first sheet during checkpoint resume.
    final nonce = (pending['nonce'] as String?) ?? 'default';

    final auth = OneDriveAuth();
    final client = OneDriveClient(auth);

    // === Phase 1: list folder + download designs ===
    _updateNotif('Loading designs', 'Listing OneDrive folder…');
    _send({'phase': 'listing'});
    // Reuses the prefetch's listing when it's under 3 minutes old — the
    // "Loading OneDrive" step then takes ~0 s.
    final files = await _listDesigns(client, folder);
    String norm(String s) => s.replaceAll(RegExp(r'[^a-zA-Z0-9]'), '').toLowerCase();
    final fileByNorm = <String, OneDriveFile>{};
    for (final f in files) {
      fileByNorm[norm(f.nameWithoutExtension)] = f;
    }

    final designIds = <String>{};
    for (final s in sheets) {
      designIds.addAll(s.slots);
    }

    // NOTE: outDir is NOT wiped here. The UI wipes it when the user starts
    // a genuinely new order (freshRender). Keeping it lets a render that
    // was killed mid-way (low memory, crash, reboot) RESUME from the files
    // already on disk instead of redoing everything. Files live under a
    // per-order nonce subdir so no two orders can ever cross-contaminate.
    final docs = await getApplicationDocumentsDirectory();
    final renderRoot = Directory('${docs.path}/last_render');
    final outDir = Directory('${renderRoot.path}/$nonce');
    // THIS pipeline is the only party allowed to delete render dirs. The UI
    // used to wipe last_render/ itself on fresh orders — which raced an
    // in-flight render and yanked its directory away mid-write
    // (PathNotFoundException on sheet_N.jpg.tmp). Stale sibling dirs from
    // previous orders are cleared HERE instead: safe, because renders are
    // strictly single-flighted through _tryRender.
    try {
      if (await renderRoot.exists()) {
        await for (final e in renderRoot.list()) {
          if (e is Directory &&
              e.uri.pathSegments.where((s) => s.isNotEmpty).last != nonce) {
            await e.delete(recursive: true);
          }
        }
      }
    } catch (_) {/* best-effort */}
    await outDir.create(recursive: true);
    // Persistent slot-sized design cache — survives across orders, so a
    // design that was ever printed before never downloads again (unless
    // its content changed on OneDrive; the cTag in the filename catches
    // that). LRU-pruned to _designCacheMaxFiles after each order.
    final cacheDir = Directory('${docs.path}/design_cache');
    await cacheDir.create(recursive: true);

    // === Phase 1b: fill the design cache, 20 downloads at a time ===
    // Fast scan first: map every ordered design to its cache path and
    // split hits (mtime-touched for LRU) from misses. Then the misses
    // download through the same 20-wide pool the prefetch uses — the
    // one-at-a-time loop was the "Preparing designs takes time" complaint.
    final designList = designIds.toList();
    final designPath = <String, String>{};
    final missing = <String>[];
    final toFetch =
        <({String id, String safe, String path, OneDriveFile file})>[];
    for (var i = 0; i < designList.length; i++) {
      _checkCancelled();
      final id = designList[i];
      final file = fileByNorm[norm(id)];
      if (file == null) {
        missing.add(id);
        continue;
      }
      final safe = id.replaceAll(RegExp(r'[^a-zA-Z0-9]'), '_');
      final ctag =
          (file.cTag ?? 'v0').replaceAll(RegExp(r'[^a-zA-Z0-9]'), '');
      // '@' can never appear in the sanitized id or ctag, so it's an
      // unambiguous separator: cleanup of design "1444" can't match files
      // of design "1444_A" (the old "__" separator could).
      final path = '${cacheDir.path}/$safe@$ctag.jpg';
      designPath[id] = path;
      final cached = File(path);
      if (await cached.exists()) {
        // Cache hit — touch mtime so LRU eviction keeps hot designs.
        try {
          await cached.setLastModified(DateTime.now());
        } catch (_) {/* some filesystems refuse — harmless */}
        continue;
      }
      toFetch.add((id: id, safe: safe, path: path, file: file));
    }
    if (missing.isNotEmpty) {
      throw StateError(
          'Designs not found in OneDrive folder "$folder": ${missing.join(", ")}');
    }

    if (toFetch.isNotEmpty) {
      const parallel = 20;
      var nextIdx = 0;
      var doneCount = 0;
      Object? firstError;
      Future<void> pump() async {
        while (true) {
          if (_cancelRequested || firstError != null) return;
          if (nextIdx >= toFetch.length) return;
          final t = toFetch[nextIdx++];
          try {
            // Old cTag leftovers die BEFORE the fresh download lands —
            // this design can't render until the new file exists anyway,
            // so nothing is hurt by the gap. Best-effort sweep.
            try {
              await for (final old in cacheDir.list()) {
                if (old is File &&
                    old.uri.pathSegments.last.startsWith('${t.safe}@')) {
                  try {
                    await old.delete();
                  } catch (_) {/* harmless */}
                }
              }
            } catch (_) {/* best-effort */}
            final original = await client.downloadFile(t.file.id);
            Uint8List slotSized;
            try {
              // Native codec (fast, runs off-thread, keeps THIS isolate
              // free for cancel/mute); pure-Dart worker fallback inside.
              slotSized =
                  await CollageRenderer.preprocessDesignFast(original);
            } catch (e) {
              throw StateError('Design "${t.id}" could not be decoded: $e');
            }
            final tmp = File('${t.path}.tmp');
            await tmp.writeAsBytes(slotSized);
            await tmp.rename(t.path);
            doneCount++;
            _updateNotif('Preparing designs',
                '${t.id}  ($doneCount/${toFetch.length})');
            _send({
              'phase': 'download',
              'label': 'Preparing ${t.id}',
              'current': doneCount,
              'total': toFetch.length,
            });
          } catch (e) {
            // Unlike the best-effort prefetch, a bad design must fail the
            // ORDER: capture the first error, drain the pool, rethrow.
            firstError ??= e;
            return;
          }
        }
      }

      _updateNotif('Preparing designs', '0/${toFetch.length}');
      _send({
        'phase': 'download',
        'label': 'Preparing designs',
        'current': 0,
        'total': toFetch.length,
      });
      await Future.wait(List.generate(parallel, (_) => pump()));
      final err = firstError;
      if (err != null) {
        Error.throwWithStackTrace(err, StackTrace.current);
      }
      _checkCancelled();
    }

    // === Phase 2: render collages in worker isolates, TWO at a time ===
    // Each sheet — decode, composite, encode, write — runs in its own
    // worker isolate (keeps this isolate responsive for cancel/mute, and
    // all render memory is reclaimed when the worker exits). Two workers
    // run concurrently: the phone has 8 cores and one sheet is otherwise
    // a single-core job, so this roughly halves wall-clock time on
    // multi-sheet orders while keeping peak memory bounded (~2×130 MB,
    // transient).
    final rendered = <_RenderedRecord>[];
    final pendingIdx = <int>[];
    for (var i = 0; i < sheets.length; i++) {
      final path = '${outDir.path}/sheet_$i.jpg';
      if (await File(path).exists()) {
        rendered.add(_RenderedRecord(index: i, path: path, plan: sheets[i]));
      } else {
        pendingIdx.add(i); // checkpoint resume: only render what's missing
      }
    }
    var doneCount = sheets.length - pendingIdx.length;
    void reportRenderProgress() {
      _updateNotif('Rendering collages', '$doneCount/${sheets.length}');
      _send({
        'phase': 'render',
        'label': 'Rendering collage ${doneCount + 1} of ${sheets.length}',
        'current': doneCount,
        'total': sheets.length,
      });
    }

    const renderConcurrency = 2;
    for (var w = 0; w < pendingIdx.length; w += renderConcurrency) {
      _checkCancelled();
      reportRenderProgress();
      final wave = pendingIdx.skip(w).take(renderConcurrency).toList();
      // Token lets each worker isolate reach the native codec's platform
      // channel; null (shouldn't happen on-device) = pure-Dart fallback.
      final isolateToken = RootIsolateToken.instance;
      await Future.wait(wave.map((i) {
        final path = '${outDir.path}/sheet_$i.jpg';
        final slots = List<String>.from(sheets[i].slots);
        final paths = <String, String>{
          for (final id in slots.toSet()) id: designPath[id]!,
        };
        return Isolate.run(() => renderSheetWorker(
              slots: slots,
              designPaths: paths,
              outPath: path,
              token: isolateToken,
            ));
      }));
      for (final i in wave) {
        rendered.add(_RenderedRecord(
            index: i, path: '${outDir.path}/sheet_$i.jpg', plan: sheets[i]));
        doneCount++;
      }
    }
    reportRenderProgress();
    // Waves can finish out of order relative to plain index order when
    // resuming — the zip phase relies on sheet order for naming, restore it.
    rendered.sort((a, b) => a.index.compareTo(b.index));

    // === Phase 3: stream the zip to disk (never hold it all in RAM) ===
    _checkCancelled();
    _updateNotif('Packaging', 'Zipping sheets…');
    _send({'phase': 'zip'});
    final now = DateTime.now();
    final zipName = '${now.day}-${now.month} - $totalSheetsToPrint.zip';
    final zipPath = '${outDir.path}/$zipName';
    final zipEncoder = ZipFileEncoder();
    zipEncoder.create(zipPath);
    final usedNames = <String, int>{};
    for (final r in rendered) {
      _checkCancelled();
      var name = r.plan.filename;
      if (usedNames.containsKey(name)) {
        usedNames[name] = usedNames[name]! + 1;
        final dot = name.lastIndexOf('.');
        // 2nd occurrence → "(a)", 3rd → "(b)", … 27th → "(aa)", 28th → "(ab)",
        // Excel-column style so the numeric design number stays unambiguous
        // (e.g. "1 (2).jpg" was easy to misread as design number "1 2").
        final suffix = _alphaSuffix(usedNames[name]! - 1);
        name = '${name.substring(0, dot)} ($suffix).jpg';
      } else {
        usedNames[r.plan.filename] = 1;
      }
      await zipEncoder.addFile(File(r.path), name);
    }
    await zipEncoder.close();

    // LRU-prune the persistent design cache so it never grows unbounded.
    // Size-based cap: evict least-recently-used designs once the cache
    // passes 20 GB (roughly 10000-20000 slot-sized designs). Orphaned
    // .tmp files (process killed mid-write) are removed unconditionally —
    // every legitimate write has completed by this point.
    try {
      const maxCacheBytes = 20 * 1024 * 1024 * 1024; // 20 GB
      final stats = <({File file, DateTime modified, int size})>[];
      var totalBytes = 0;
      await for (final e in cacheDir.list()) {
        if (e is! File) continue;
        if (e.path.endsWith('.tmp')) {
          try {
            await e.delete();
          } catch (_) {/* harmless */}
          continue;
        }
        if (e.path.endsWith('.jpg')) {
          final s = await e.stat();
          stats.add((file: e, modified: s.modified, size: s.size));
          totalBytes += s.size;
        }
      }
      if (totalBytes > maxCacheBytes) {
        stats.sort((a, b) => a.modified.compareTo(b.modified)); // oldest first
        for (final entry in stats) {
          if (totalBytes <= maxCacheBytes) break;
          try {
            await entry.file.delete();
            totalBytes -= entry.size;
          } catch (_) {/* harmless */}
        }
      }
    } catch (_) {/* cache pruning is best-effort */}

    // Drop checkpoint dirs from OTHER orders (older nonces) — they're
    // dead weight now that this order is complete.
    try {
      await for (final e in renderRoot.list()) {
        if (e is Directory && e.uri.pathSegments.where((s) => s.isNotEmpty).last != nonce) {
          await e.delete(recursive: true);
        }
      }
    } catch (_) {/* best-effort */}

    // === Phase 3.5: upload to Google Drive + create a pre-shared link ===
    // Gmail converts attachments over 25 MB into a Drive link that asks the
    // recipient for permission. Instead we upload the ZIP ourselves and put
    // an "anyone with the link can view" URL in the email — no prompt ever.
    _checkCancelled();
    String? shareUrl;
    if (await GDriveUploader.isConfigured()) {
      _updateNotif('Uploading order', 'Sending $zipName to Google Drive…');
      _send({'phase': 'upload'});
      try {
        shareUrl = await GDriveUploader.uploadAndShare(File(zipPath), zipName);
      } catch (e) {
        final zipBytes = await File(zipPath).length();
        if (zipBytes <= 20 * 1024 * 1024) {
          // Small enough to ride as a plain attachment — degrade gracefully.
          shareUrl = null;
        } else {
          throw StateError('Google Drive upload failed for $zipName: $e');
        }
      }
    }

    // Final gate: if the user cancelled while we were zipping/uploading,
    // the order must NOT be declared ready (no meta, no alarm).
    _checkCancelled();

    // === Write the completion metadata so the UI can pick it up ===
    final meta = {
      'completedAt': now.toIso8601String(),
      'zipName': zipName,
      'zipPath': zipPath,
      'shareUrl': ?shareUrl,
      'sheets': rendered.map((r) => {
            'index': r.index,
            'path': r.path,
            'slots': r.plan.slots,
            'copies': r.plan.copies,
          }).toList(),
    };
    await prefs.setString(OrderRenderConstants.lastRenderPrefKey, jsonEncode(meta));
    await prefs.setString(OrderRenderConstants.pendingOrderPrefKey, '');

    _updateNotif('Order ready', 'Tap to open and send');
    // Looping alarm so the user doesn't miss it. Stops as soon as they
    // bring the app to foreground (the UI sends actionMute on resume).
    await _startAlarm();
    _send({'phase': 'complete'});
  }

  void _updateNotif(String title, String text) {
    FlutterForegroundTask.updateService(
      notificationTitle: title,
      notificationText: text,
    );
  }

  void _send(Map<String, dynamic> data) {
    FlutterForegroundTask.sendDataToMain(data);
  }

  Future<void> _sendError(String message) async {
    final shortMsg = message.length > 80 ? '${message.substring(0, 80)}…' : message;
    _updateNotif('Order failed', shortMsg);
    _send({'phase': 'error', 'message': message});
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      OrderRenderConstants.lastRenderPrefKey,
      jsonEncode({
        'error': message,
        'failedAt': DateTime.now().toIso8601String(),
      }),
    );
  }
}

class _RenderedRecord {
  final int index;
  final String path;
  final SheetPlan plan;
  _RenderedRecord({required this.index, required this.path, required this.plan});
}

/// Excel-style column suffix: 1→a, 2→b, …, 26→z, 27→aa, 28→ab, …, 52→az,
/// 53→ba, … Used to label duplicate-named sheets inside the order ZIP
/// without ambiguity vs numeric design IDs.
String _alphaSuffix(int n) {
  var result = '';
  var x = n;
  while (x > 0) {
    x -= 1;
    final code = 'a'.codeUnitAt(0) + (x % 26);
    result = String.fromCharCode(code) + result;
    x ~/= 26;
  }
  return result.isEmpty ? 'a' : result;
}
