import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_email_sender/flutter_email_sender.dart' as fes;
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/sheet_plan.dart';
import '../services/design_library.dart';
import '../services/order_alarm.dart';
import '../services/order_render_task.dart';
import '../services/password_prompt.dart';
import '../services/settings_store.dart';

/// What the PreviewScreen returned via Navigator.pop. Lets OrderScreen
/// distinguish "we sent it" (clear rows) from "we want to edit" (keep
/// rows + show editing banner) from a plain back nav.
enum PreviewResult { sent, edited, cancelled }

class PreviewScreen extends StatefulWidget {
  final PackingResult result;
  final AppSettings settings;
  final DesignLibrary designLibrary;

  /// True when the user just tapped Continue on the order screen — we
  /// must wipe any stale render artifacts and start a fresh background
  /// render. False when we're resuming via the "previous order still
  /// rendering" banner, in which case we attach to the running service
  /// or load the completed result from disk.
  final bool freshRender;

  const PreviewScreen({
    super.key,
    required this.result,
    required this.settings,
    required this.designLibrary,
    this.freshRender = false,
  });

  @override
  State<PreviewScreen> createState() => _PreviewScreenState();
}

class _PreviewScreenState extends State<PreviewScreen> {
  // Progress state pushed from the background isolate.
  String _statusLabel = 'Starting…';
  int _stepCurrent = 0;
  int _stepTotal = 0;
  DateTime? _phaseStartTime;

  // Terminal states.
  String? _errorMessage;
  _RenderResult? _result;

  /// Set once a pop (send/edit/cancel) is committed. Blocks double-taps
  /// from popping the navigator twice (which would dismiss the home
  /// screen too and leave a black screen).
  bool _closing = false;

  late final void Function(Object) _taskDataCallback;

  @override
  void initState() {
    super.initState();
    _taskDataCallback = _onTaskData;
    FlutterForegroundTask.addTaskDataCallback(_taskDataCallback);
    _bootstrap();
    // Warm Flutter's image cache with every summary thumbnail up front —
    // the files are already on disk, so by the time the user scrolls the
    // pictures are simply THERE, no per-row loading flash.
    WidgetsBinding.instance.addPostFrameCallback((_) => _precacheThumbs());
  }

  Future<void> _precacheThumbs() async {
    for (final id in widget.result.requestedByDesign.keys) {
      final f = await widget.designLibrary.getCachedDesignFile(id);
      if (!mounted) return;
      if (f == null) continue;
      try {
        await precacheImage(
          ResizeImage(FileImage(f), width: 240, height: 360),
          context,
        );
      } catch (_) {/* corrupt file — row falls back to network thumb */}
      if (!mounted) return;
    }
  }

  @override
  void dispose() {
    FlutterForegroundTask.removeTaskDataCallback(_taskDataCallback);
    super.dispose();
  }

  /// Decide whether to start a new background render (because we just
  /// arrived from the order screen) or just attach to a render already
  /// in progress / load a finished one (because the user is coming back
  /// from the notification).
  Future<void> _bootstrap() async {
    final prefs = await SharedPreferences.getInstance();
    // SharedPreferences caches values per isolate; the background isolate
    // may have written results after our cache was populated. Force a
    // disk reread so getString returns the up-to-date values.
    await prefs.reload();

    // Fresh Continue — wipe any stale result from a prior order so the
    // Mail Check tab doesn't show old sheets while the new render runs.
    if (widget.freshRender) {
      await prefs.remove(OrderRenderConstants.lastRenderPrefKey);
      // NOTE: no directory deletion here. Only the render pipeline touches
      // last_render/ — a UI-side wipe raced in-flight renders and deleted
      // their checkpoint dir mid-write. Stale dirs are cleaned by the
      // pipeline itself at the start of the next render.
      await _startBackgroundRender(prefs);
      return;
    }

    final completed = prefs.getString(OrderRenderConstants.lastRenderPrefKey) ?? '';
    // Service is always running for OneDrive sync, so isRunningService is
    // no longer a useful "render in progress" signal. Use unconsumed
    // last_render_meta instead — its presence means the user has a result
    // waiting to be picked up.
    if (completed.isNotEmpty) {
      _loadCompleted(completed);
      return;
    }

    // No completed result yet. We can't tell from out here whether the
    // handler is mid-render or idle (it could have been wiped by a
    // process restart). Just kick it again — the handler's _tryRender
    // dedupes if one is already in progress.
    await _startBackgroundRender(prefs);
  }

  /// Pop THIS screen with [result], never whatever route happens to be on
  /// top. A delayed pop that lands while a dialog is open would otherwise
  /// close the dialog and hand it a PreviewResult it can't cast.
  void _popSelf(PreviewResult result) {
    if (!mounted) return;
    final route = ModalRoute.of(context);
    if (route == null) return;
    if (!route.isCurrent) {
      // A dialog is on top — close it first, then pop this screen.
      Navigator.of(context).popUntil((r) => r == route);
    }
    if (!mounted) return;
    Navigator.of(context).pop(result);
  }

  /// True when the stored render meta is a failure record rather than a
  /// finished order. Both live under lastRenderPrefKey.
  bool _isErrorBlob(String metaJson) {
    try {
      final data = jsonDecode(metaJson);
      return data is Map && data.containsKey('error');
    } catch (_) {
      return true; // unparseable → treat as failure, never as a result
    }
  }

  Future<void> _startBackgroundRender(SharedPreferences prefs) async {
    if (widget.freshRender) {
      // New order — stale results were already wiped in _bootstrap.
      await prefs.remove(OrderRenderConstants.lastRenderPrefKey);
    } else {
      // Resume path. A completing render may have JUST written its result
      // between our earlier check and now — re-check instead of nuking it.
      // A FAILURE blob lives under the same key though: short-circuiting on
      // that would make Retry re-show the same error forever, so only a
      // successful result wins; an error blob is cleared and we re-render.
      await prefs.reload();
      final done =
          prefs.getString(OrderRenderConstants.lastRenderPrefKey) ?? '';
      if (done.isNotEmpty) {
        if (!_isErrorBlob(done)) {
          _loadCompleted(done);
          return;
        }
        await prefs.remove(OrderRenderConstants.lastRenderPrefKey);
      }
    }
    // Serialize the order so the background isolate can pick it up. The
    // nonce keys this order's checkpoint directory so leftovers from a
    // cancelled order can never leak into this one.
    final pending = jsonEncode({
      'folder': widget.settings.oneDriveFolder,
      'totalSheetsToPrint': widget.result.totalSheetsToPrint,
      'nonce': DateTime.now().millisecondsSinceEpoch.toString(),
      'sheets': widget.result.sheets
          .map((s) => {'slots': s.slots, 'copies': s.copies})
          .toList(),
    });
    await prefs.setString(OrderRenderConstants.pendingOrderPrefKey, pending);
    await prefs.setString(
      OrderRenderConstants.activeOrderResultPrefKey,
      jsonEncode(_packingResultToJson(widget.result)),
    );

    // The persistent background service is normally already running
    // (main() ensures it on every launch). If it isn't, start it — and
    // treat "already started" as success: app-launch init and this call
    // can race, both trying to start the same service.
    if (!await FlutterForegroundTask.isRunningService) {
      final notifPermission =
          await FlutterForegroundTask.checkNotificationPermission();
      if (notifPermission != NotificationPermission.granted) {
        await FlutterForegroundTask.requestNotificationPermission();
      }
      final start = await FlutterForegroundTask.startService(
        serviceId: 421,
        notificationTitle: 'Preparing order…',
        notificationText: 'Connecting to OneDrive',
        notificationIcon: null,
        notificationButtons: const [],
        callback: orderRenderTaskEntryPoint,
      );
      if (start is ServiceRequestFailure) {
        // Usually a benign race ("The service has already started").
        // Poll briefly; only surface an error if it's truly not running.
        var running = false;
        for (var i = 0; i < 10 && !running; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 300));
          running = await FlutterForegroundTask.isRunningService;
        }
        if (!running) {
          if (mounted) {
            setState(() {
              _errorMessage =
                  'Could not start background service: ${start.error}';
            });
          }
          return;
        }
      }
    }
    FlutterForegroundTask.sendDataToTask({
      OrderRenderConstants.actionKey: OrderRenderConstants.actionRender,
    });
    // Belt & braces: if the service isolate wasn't ready yet, the message
    // above is lost. The handler's onStart auto-resume usually covers it,
    // but re-kick once after a beat if no progress has arrived. The
    // handler dedupes, so a double render request is harmless.
    Future<void>.delayed(const Duration(seconds: 3), () {
      if (!mounted) return;
      if (_result == null && _errorMessage == null && _stepTotal == 0) {
        FlutterForegroundTask.sendDataToTask({
          OrderRenderConstants.actionKey: OrderRenderConstants.actionRender,
        });
      }
    });
    if (mounted) {
      setState(() {
        _statusLabel = 'Loading designs from OneDrive…';
        _phaseStartTime = DateTime.now();
      });
    }
  }

  void _onTaskData(Object data) {
    if (data is! Map) return;
    final phase = data['phase'] as String?;
    if (phase == null) return;
    final current = data['current'];
    final total = data['total'];
    final label = data['label'] as String?;
    if (!mounted) return;
    setState(() {
      if (label != null) _statusLabel = label;
      if (current is int) _stepCurrent = current;
      if (total is int) _stepTotal = total;
      if (phase == 'download' && _phaseStartTime == null) {
        _phaseStartTime = DateTime.now();
      }
    });
    if (phase == 'render' && _stepCurrent == 0) {
      _phaseStartTime = DateTime.now();
    }
    if (phase == 'zip') {
      setState(() {
        _statusLabel = 'Packaging into one zip…';
        _stepCurrent = 0;
        _stepTotal = 1;
      });
    }
    if (phase == 'upload') {
      setState(() {
        _statusLabel = 'Uploading order to Google Drive…';
        _stepCurrent = 0;
        _stepTotal = 0; // indeterminate
      });
    }
    if (phase == 'complete') {
      // Do NOT mute here — see THE RINGTONE ACKNOWLEDGEMENT LAW in
      // order_alarm.dart. This event is automatic; if the user is watching
      // this screen it fires the instant the ring starts. Just record that
      // the ring is live so their next tap (or app resume) silences it.
      markOrderAlarmRinging();
      _finishFromService();
    } else if (phase == 'error') {
      setState(() {
        _errorMessage = (data['message'] as String?) ?? 'Render failed';
      });
      // No stopService call — the background service is persistent.
    }
  }

  Future<void> _finishFromService() async {
    final prefs = await SharedPreferences.getInstance();
    // Cross-isolate cache invalidation — the background isolate's writes
    // need to be flushed into our SharedPreferences view before we read.
    await prefs.reload();
    final meta = prefs.getString(OrderRenderConstants.lastRenderPrefKey) ?? '';
    // Service is persistent (handles OneDrive auto-sync); no stopService call.
    if (meta.isEmpty) {
      // The service told us it's done but the metadata isn't on disk yet
      // (rare race). Retry once with a short backoff before giving up.
      await Future<void>.delayed(const Duration(milliseconds: 250));
      await prefs.reload();
      final retry = prefs.getString(OrderRenderConstants.lastRenderPrefKey) ?? '';
      if (!mounted) return;
      if (retry.isEmpty) {
        setState(() => _errorMessage =
            'Render finished but no result was written. Tap retry.');
        return;
      }
      _loadCompleted(retry);
      return;
    }
    if (!mounted) return;
    _loadCompleted(meta);
  }

  void _loadCompleted(String metaJson) {
    if (!mounted) return;
    if (metaJson.isEmpty) {
      setState(() => _errorMessage =
          'No render result on disk yet. Tap retry to start over.');
      return;
    }
    try {
      final data = jsonDecode(metaJson) as Map<String, dynamic>;
      if (data.containsKey('error')) {
        setState(() => _errorMessage = data['error'] as String);
        return;
      }
      final sheets = (data['sheets'] as List).cast<Map<String, dynamic>>().map((s) {
        return _RenderedSheet(
          path: s['path'] as String,
          plan: SheetPlan(
            slots: (s['slots'] as List).cast<String>(),
            copies: s['copies'] as int,
          ),
        );
      }).toList();
      setState(() {
        _result = _RenderResult(
          zipPath: data['zipPath'] as String,
          zipName: data['zipName'] as String,
          shareUrl: data['shareUrl'] as String?,
          sheets: sheets,
        );
      });
      // NO mute here — see THE RINGTONE ACKNOWLEDGEMENT LAW in
      // order_alarm.dart. This runs on the live completion path, so muting
      // here (even visibility-gated) killed the ring the instant it
      // started whenever the user was watching the render. Acknowledgement
      // comes from cold-open, app resume, or a screen tap — never from
      // result loading.
    } catch (e) {
      setState(() => _errorMessage = 'Could not load result: $e');
    }
  }

  double get _progressFraction =>
      _stepTotal == 0 ? 0 : (_stepCurrent / _stepTotal).clamp(0.0, 1.0);

  String get _etaText {
    if (_phaseStartTime == null || _stepCurrent == 0) return 'estimating…';
    final elapsed = DateTime.now().difference(_phaseStartTime!);
    final perStep = elapsed.inMilliseconds / _stepCurrent;
    final remaining = Duration(milliseconds: ((_stepTotal - _stepCurrent) * perStep).round());
    if (remaining.inSeconds < 1) return 'almost done';
    if (remaining.inSeconds < 60) return '~${remaining.inSeconds}s left';
    final m = remaining.inMinutes;
    final s = remaining.inSeconds % 60;
    return '~${m}m ${s}s left';
  }

  Future<void> _send() async {
    // Don't fire the email intent for an order that's being cancelled or
    // edited (its files are about to be wiped).
    if (_closing) return;
    final email = widget.settings.destinationEmail;
    if (email.isEmpty) {
      _showInfoDialog(
        'No destination email',
        'Open Settings (gear icon on Order screen) and set a destination email first.',
      );
      return;
    }
    final result = _result;
    if (result == null) return;

    // Password gate.
    final required = widget.settings.sendPassword;
    if (required.isNotEmpty) {
      final ok = await promptForPassword(
        context: context,
        expected: required,
        title: 'Enter send password',
        description: 'A password is required before opening the email app.',
      );
      if (ok != true) return;
    }

    try {
      // With a pre-shared Drive link, the email is just the link — tiny, so
      // Gmail never converts anything and the recipient opens it as Viewer
      // with zero permission prompts. Without one (Drive not configured),
      // fall back to attaching the ZIP directly.
      final emailObj = fes.Email(
        body: result.shareUrl != null
            ? '${result.zipName}\n\n${result.shareUrl}'
            : '',
        subject: '',
        recipients: [email],
        // Always CC the workshop coordinator so every order is logged.
        cc: const ['aknzone@gmail.com'],
        attachmentPaths: result.shareUrl != null ? const [] : [result.zipPath],
        isHTML: false,
      );
      await fes.FlutterEmailSender.send(emailObj);
      if (!mounted) return;
      await _showSuccessAndGoHome(email);
    } catch (e) {
      if (!mounted) return;
      await _showErrorDialog('Could not open email app', e.toString());
    }
  }

  Future<void> _showSuccessAndGoHome(String email) async {
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        icon: const Icon(Icons.check_circle, color: Colors.green, size: 48),
        title: const Text('Email ready!'),
        content: Text(
          'Email opened in your email app.\n\nTo: $email\n\nTap Send in your email app to deliver.',
        ),
        actions: [
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('OK'),
          ),
        ],
      ),
    );
    if (!mounted || _closing) return;
    _closing = true;
    // Clean up: clear all order-related prefs so the next order starts
    // fresh. pendingOrder goes FIRST — if the process dies mid-cleanup,
    // the auto-resume condition (pending set && lastRender empty) must
    // never be true for an already-sent order.
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(OrderRenderConstants.pendingOrderPrefKey);
    await prefs.remove(OrderRenderConstants.activeOrderResultPrefKey);
    await prefs.remove(OrderRenderConstants.lastRenderPrefKey);
    if (!mounted) return;
    _popSelf(PreviewResult.sent);
  }

  Future<void> _showErrorDialog(String title, String message) async {
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        icon: const Icon(Icons.error_outline, color: Colors.red, size: 40),
        title: Text(title),
        content: SingleChildScrollView(child: Text(message)),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('OK'),
          ),
        ],
      ),
    );
  }

  Future<void> _showInfoDialog(String title, String message) async {
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: Text(message),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('OK'),
          ),
        ],
      ),
    );
  }

  /// Abandon the current order — stop the background service, wipe the
  /// pending/active/last-render prefs, delete any rendered files on disk,
  /// then pop back to the order screen.
  Future<void> _cancelOrder() async {
    // Entry guard: without it, tapping Cancel during Edit's unwind window
    // would open this dialog and Edit's delayed pop would then target the
    // DIALOG route — a type crash that left the screen permanently stuck.
    if (_closing) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        icon: const Icon(Icons.delete_outline, color: Colors.red, size: 40),
        title: const Text('Cancel this order?'),
        content: const Text(
          'The background render will stop and the prepared sheets will be discarded. '
          'You can start a fresh order afterwards.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Keep'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Cancel order'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted || _closing) return;
    _closing = true;

    // Clear the pending order BEFORE signalling cancel: if the process
    // dies in the window below, the service's auto-resume must not find a
    // pending order and resurrect the very order we're cancelling.
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(OrderRenderConstants.pendingOrderPrefKey);

    // Tell the background isolate to abort the in-flight render, then give
    // it a beat to reach a safe checkpoint before we wipe its files.
    FlutterForegroundTask.sendDataToTask({
      OrderRenderConstants.actionKey: OrderRenderConstants.actionCancel,
    });
    await Future<void>.delayed(const Duration(milliseconds: 400));

    // Wipe the rest so nothing auto-resumes on next app launch. The
    // rendered files on disk are NOT deleted here — only the pipeline may
    // touch last_render/ (a UI wipe raced in-flight renders); the next
    // order's pipeline clears the stale dir at start.
    await prefs.remove(OrderRenderConstants.activeOrderResultPrefKey);
    await prefs.remove(OrderRenderConstants.lastRenderPrefKey);

    if (!mounted) return;
    _popSelf(PreviewResult.cancelled);
  }

  /// Edit mode: stop the current render but KEEP the user's typed rows
  /// on the order screen so they can tweak quantities and continue with
  /// a fresh render. Returns [PreviewResult.edited] so the order screen
  /// can show its "editing last order" banner.
  Future<void> _editOrder() async {
    if (_closing) return; // double-tap guard — one pop only
    _closing = true;
    // Clear the pending order BEFORE signalling cancel — see _cancelOrder:
    // a process death mid-cancel must not auto-resume the abandoned order.
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(OrderRenderConstants.pendingOrderPrefKey);
    // Abort the in-flight render immediately — the user is changing the
    // order, so finishing the old one is wasted work.
    FlutterForegroundTask.sendDataToTask({
      OrderRenderConstants.actionKey: OrderRenderConstants.actionCancel,
    });
    await Future<void>.delayed(const Duration(milliseconds: 400));
    await prefs.remove(OrderRenderConstants.activeOrderResultPrefKey);
    await prefs.remove(OrderRenderConstants.lastRenderPrefKey);
    // No directory deletion — pipeline-owned; see _cancelOrder.
    if (!mounted) return;
    _popSelf(PreviewResult.edited);
  }

  Future<void> _retry() async {
    setState(() {
      _errorMessage = null;
      _result = null;
      _statusLabel = 'Starting…';
      _stepCurrent = 0;
      _stepTotal = 0;
      _phaseStartTime = null;
    });
    final prefs = await SharedPreferences.getInstance();
    // Drop the failure record first — otherwise the resume path would read
    // it back and re-display the same error instead of re-rendering.
    await prefs.remove(OrderRenderConstants.lastRenderPrefKey);
    await _startBackgroundRender(prefs);
  }

  Future<void> _openMailCheck() async {
    // The Mail Check screen is a snapshot — opening it mid-render would
    // show a spinner that never resolves (progress events land on THIS
    // screen's state, not that one's). Gate it until the result exists.
    if (_errorMessage != null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Render failed — fix the error first')),
      );
      return;
    }
    if (_result == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Still rendering — Mail Check opens when the order is ready'),
          duration: Duration(seconds: 2),
        ),
      );
      return;
    }
    await Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => _MailCheckScreen(
        result: _result,
        errorMessage: _errorMessage,
        statusLabel: _statusLabel,
        onRetry: _retry,
      ),
    ));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Preview & Send'),
        actions: [
          IconButton(
            icon: const Icon(Icons.collections_outlined),
            tooltip: 'Mail check (see rendered collages)',
            onPressed: _openMailCheck,
          ),
          IconButton(
            icon: const Icon(Icons.edit_outlined),
            tooltip: 'Edit order',
            onPressed: _editOrder,
          ),
          IconButton(
            icon: const Icon(Icons.delete_outline),
            tooltip: 'Cancel order',
            onPressed: _cancelOrder,
          ),
        ],
      ),
      body: _buildBody(),
      bottomNavigationBar: _result == null
          ? null
          : SafeArea(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: FilledButton.icon(
                  icon: const Icon(Icons.send),
                  onPressed: _send,
                  label: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    child: Text('Send to ${widget.settings.destinationEmail}',
                        style: const TextStyle(fontSize: 15)),
                  ),
                ),
              ),
            ),
    );
  }


  Widget _buildBody() {
    // The summary list and the render status panel are split so the
    // status (which ticks many times per second during download) doesn't
    // force every summary row's image FutureBuilder to rebuild.
    final r = widget.result;
    final designEntries = r.requestedByDesign.entries.toList();

    // 2 fixed items on top (status banner + totals card + section title)
    // and then one row per design. Using ListView.builder keeps memory
    // bounded — only the visible rows are constructed.
    const headerCount = 3;
    return ListView.builder(
      padding: const EdgeInsets.all(16),
      itemCount: headerCount + designEntries.length,
      itemBuilder: (ctx, i) {
        if (i == 0) {
          if (_errorMessage != null) return _renderErrorCard();
          if (_result == null) return _renderStatusCard();
          return const SizedBox.shrink();
        }
        if (i == 1) {
          final sheetWord = r.totalSheetsToPrint == 1 ? 'sheet' : 'sheets';
          final printWord = r.totalPrintsRequested == 1 ? 'print' : 'prints';
          final base = 'Total: ${r.totalSheetsToPrint} $sheetWord — '
              '${r.totalPrintsRequested} $printWord';
          final display = r.extras > 0 ? '$base (${r.extras} extras)' : base;
          return Card(
            color: Theme.of(context).colorScheme.primaryContainer,
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Text(
                display,
                style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
              ),
            ),
          );
        }
        if (i == 2) {
          return Padding(
            padding: const EdgeInsets.fromLTRB(4, 16, 4, 8),
            child: Text(
              'Order summary',
              style: Theme.of(context).textTheme.titleMedium,
            ),
          );
        }
        final entry = designEntries[i - headerCount];
        return _DesignSummaryRow(
          key: ValueKey('summary-${entry.key}'),
          designId: entry.key,
          qty: entry.value,
          designLibrary: widget.designLibrary,
        );
      },
    );
  }

  Widget _renderStatusCard() {
    final pct = (_progressFraction * 100).clamp(0, 100).toStringAsFixed(0);
    return Card(
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    _statusLabel,
                    style: const TextStyle(fontWeight: FontWeight.w500),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            ClipRRect(
              borderRadius: BorderRadius.circular(6),
              child: LinearProgressIndicator(
                value: _stepTotal == 0 ? null : _progressFraction,
                minHeight: 8,
              ),
            ),
            const SizedBox(height: 6),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  _stepTotal > 0 ? '$pct%' : '…',
                  style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
                ),
                Text(
                  _stepTotal > 0 ? '$_stepCurrent / $_stepTotal' : '',
                  style: const TextStyle(fontSize: 12, color: Colors.grey),
                ),
                Text(_etaText,
                    style: const TextStyle(fontSize: 12, color: Colors.grey)),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              'Rendering in the background. You can close the app — the notification will say "Order ready" when done.',
              style: TextStyle(
                fontSize: 11,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _renderErrorCard() {
    return Card(
      color: Theme.of(context).colorScheme.errorContainer.withValues(alpha: 0.4),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.error_outline, color: Theme.of(context).colorScheme.error),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    _errorMessage ?? 'Render failed',
                    style: TextStyle(
                      fontWeight: FontWeight.w600,
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            OutlinedButton.icon(
              icon: const Icon(Icons.refresh),
              onPressed: _retry,
              label: const Text('Retry'),
            ),
          ],
        ),
      ),
    );
  }

}

Map<String, dynamic> _packingResultToJson(PackingResult r) => {
      'sheets': r.sheets
          .map((s) => {'slots': s.slots, 'copies': s.copies})
          .toList(),
      'requestedByDesign': r.requestedByDesign,
      'producedByDesign': r.producedByDesign,
    };

/// Reverse of [_packingResultToJson] — used by OrderScreen when restoring
/// an in-flight order after Android killed and restarted the activity.
PackingResult packingResultFromJson(Map<String, dynamic> data) {
  final sheets = (data['sheets'] as List).cast<Map<String, dynamic>>().map((s) {
    return SheetPlan(
      slots: (s['slots'] as List).cast<String>(),
      copies: s['copies'] as int,
    );
  }).toList();
  final requested = (data['requestedByDesign'] as Map).cast<String, dynamic>().map(
        (k, v) => MapEntry(k, v as int),
      );
  final produced = (data['producedByDesign'] as Map).cast<String, dynamic>().map(
        (k, v) => MapEntry(k, v as int),
      );
  return PackingResult(
    sheets: sheets,
    requestedByDesign: requested,
    producedByDesign: produced,
  );
}

class _RenderResult {
  final String zipPath;
  final String zipName;

  /// Pre-shared Google Drive view link (anyone with the link → Viewer).
  /// When present the email carries this link instead of the attachment,
  /// so Gmail never converts the mail into its own permission-gated Drive
  /// link. Null = Drive upload not configured → attach the ZIP directly.
  final String? shareUrl;
  final List<_RenderedSheet> sheets;
  _RenderResult({
    required this.zipPath,
    required this.zipName,
    this.shareUrl,
    required this.sheets,
  });
}

class _RenderedSheet {
  final String path;
  final SheetPlan plan;
  _RenderedSheet({required this.path, required this.plan});
}

/// Pushed when the user taps the small "Mail Check" icon in the preview
/// AppBar. Shows the rendered 12x18 collage JPGs with filenames — the
/// operator's last visual sanity check before tapping Send.
class _MailCheckScreen extends StatelessWidget {
  final _RenderResult? result;
  final String? errorMessage;
  final String statusLabel;
  final Future<void> Function() onRetry;
  const _MailCheckScreen({
    required this.result,
    required this.errorMessage,
    required this.statusLabel,
    required this.onRetry,
  });

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Mail Check')),
      body: _body(context),
    );
  }

  Widget _body(BuildContext context) {
    if (errorMessage != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.error_outline,
                  size: 56, color: Theme.of(context).colorScheme.error),
              const SizedBox(height: 12),
              Text(errorMessage!, textAlign: TextAlign.center),
              const SizedBox(height: 16),
              OutlinedButton.icon(
                icon: const Icon(Icons.refresh),
                onPressed: () async {
                  await onRetry();
                  if (context.mounted) Navigator.of(context).pop();
                },
                label: const Text('Retry'),
              ),
            ],
          ),
        ),
      );
    }
    if (result == null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const SizedBox(
                width: 32,
                height: 32,
                child: CircularProgressIndicator(),
              ),
              const SizedBox(height: 12),
              Text(statusLabel, textAlign: TextAlign.center),
              const SizedBox(height: 8),
              Text(
                'Collages will appear here once rendering is done.',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 12,
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
      );
    }
    return ListView.builder(
      padding: const EdgeInsets.all(16),
      itemCount: result!.sheets.length,
      itemBuilder: (ctx, i) => _SheetPreviewCard(
        index: i + 1,
        sheet: result!.sheets[i],
      ),
    );
  }
}

/// One card on the Mail Check screen — shows the rendered 12x18 collage
/// JPG plus the filename that will appear in the email's ZIP attachment.
/// cacheWidth keeps the decoded bitmap small even though the underlying
/// JPG is full print resolution.
class _SheetPreviewCard extends StatelessWidget {
  final int index;
  final _RenderedSheet sheet;
  const _SheetPreviewCard({required this.index, required this.sheet});

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.only(bottom: 16),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                CircleAvatar(child: Text('$index')),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        sheet.plan.filename,
                        style: const TextStyle(
                            fontWeight: FontWeight.w600, fontSize: 16),
                      ),
                      Text(
                        sheet.plan.descriptiveName,
                        style: const TextStyle(fontSize: 12, color: Colors.grey),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 360),
              child: Center(
                child: AspectRatio(
                  aspectRatio: 12 / 18,
                  child: Image.file(
                    File(sheet.path),
                    fit: BoxFit.contain,
                    cacheWidth: 600,
                    cacheHeight: 900,
                    errorBuilder: (ctx, error, stack) => Container(
                      color: Colors.grey.shade100,
                      child: const Center(
                        child: Icon(Icons.broken_image_outlined,
                            size: 48, color: Colors.grey),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// One row in the order summary: thumbnail + design id + qty (and any
/// extras the packer had to add to fill the final sheet). Thumbnails come
/// from the existing DesignLibrary cache — same source the order screen
/// uses, so they're typically already in memory.
class _DesignSummaryRow extends StatefulWidget {
  final String designId;
  final int qty;
  final DesignLibrary designLibrary;
  const _DesignSummaryRow({
    // Key by design so the row (and its cached future) is reused across
    // rebuilds — progress ticks fire setState many times per second and
    // must not re-trigger thumbnail fetches.
    super.key,
    required this.designId,
    required this.qty,
    required this.designLibrary,
  });

  @override
  State<_DesignSummaryRow> createState() => _DesignSummaryRowState();
}

class _DesignSummaryRowState extends State<_DesignSummaryRow> {
  File? _thumbFile; // local design file — the instant path
  Uint8List? _thumb; // network-thumbnail fallback bytes
  bool _searching = true;
  int _attempt = 0;

  String get designId => widget.designId;
  int get qty => widget.qty;

  @override
  void initState() {
    super.initState();
    _loadThumb();
  }

  Future<void> _loadThumb() async {
    // 1) Local design cache: guaranteed on disk for any design the
    //    pipeline has rendered — works offline, no OneDrive listing
    //    needed. File-based so Flutter's image cache (pre-warmed by
    //    _precacheThumbs) serves the decoded bitmap instantly.
    final localFile =
        await widget.designLibrary.getCachedDesignFile(widget.designId);
    if (!mounted) return;
    if (localFile != null) {
      setState(() {
        _thumbFile = localFile;
        _searching = false;
      });
      return;
    }
    // 2) OneDrive thumbnail (needs the listing + network).
    final net = await widget.designLibrary
        .getThumbnail(widget.designId, size: 'c300x450');
    if (!mounted) return;
    if (net != null) {
      setState(() {
        _thumb = net;
        _searching = false;
      });
      return;
    }
    // 3) Both empty — usually the design is still downloading (screen was
    //    opened mid-render) or the network blipped. Retry quietly; the
    //    local cache will win as soon as the pipeline writes the file.
    //    NEVER show a broken-image icon while this settles.
    if (_attempt < 20) {
      _attempt++;
      await Future.delayed(const Duration(seconds: 4));
      if (mounted) await _loadThumb();
    } else {
      setState(() => _searching = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(8),
              // 120x180 visual, but we decode to ~240px wide so the
              // bitmap stays small in memory (cacheWidth) — full-size
              // c600x900 thumbs were OOM-killing the activity on long
              // order lists.
              child: SizedBox(
                width: 120,
                height: 180,
                child: _thumbFile != null
                    ? Image.file(
                        _thumbFile!,
                        fit: BoxFit.cover,
                        gaplessPlayback: true,
                        cacheWidth: 240,
                        cacheHeight: 360,
                      )
                    : _thumb != null
                    ? Image.memory(
                        _thumb!,
                        fit: BoxFit.cover,
                        gaplessPlayback: true,
                        cacheWidth: 240,
                        cacheHeight: 360,
                      )
                    : Container(
                        color: Colors.grey.shade200,
                        child: _searching
                            ? const Center(
                                child: SizedBox(
                                  width: 20,
                                  height: 20,
                                  child:
                                      CircularProgressIndicator(strokeWidth: 2),
                                ),
                              )
                            // Deliberately plain — the broken-image icon
                            // made a finished order look damaged.
                            : null,
                      ),
              ),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text(
                    designId,
                    style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 22),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    '$qty pcs',
                    style: TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.w600,
                      color: Theme.of(context).colorScheme.primary,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
