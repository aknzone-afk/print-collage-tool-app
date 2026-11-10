import 'package:flutter/material.dart';

import 'dart:convert';
import 'dart:io';

import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/order_line.dart';
import '../models/sheet_plan.dart';
import '../services/design_library.dart';
import '../services/order_alarm.dart';
import '../services/order_render_task.dart';
import '../services/packing.dart';
import '../services/password_prompt.dart';
import '../services/settings_store.dart';
import 'preview_screen.dart';
import 'settings_screen.dart';

/// SharedPreferences key holding the typed order rows (design + qty) as
/// JSON. Written on Continue; restored when the user taps Edit — even if
/// Android killed and recreated the activity in between.
const String _kEnteredOrderLinesPref = 'entered_order_lines';


class OrderScreen extends StatefulWidget {
  final AppSettings settings;
  final DesignLibrary designLibrary;
  const OrderScreen({super.key, required this.settings, required this.designLibrary});

  @override
  State<OrderScreen> createState() => _OrderScreenState();
}

class _OrderScreenState extends State<OrderScreen> with WidgetsBindingObserver {
  final List<_OrderRowController> _rows = [];
  bool _loadingDesigns = false;
  // Live "downloading new designs" banner state (0 total = hidden).
  int _prefetchDone = 0;
  int _prefetchTotal = 0;
  String _prefetchLabel = '';
  String? _designLoadError;
  int _designCount = 0;

  bool _hasActiveRender = false;
  /// Ensures the auto-open jump to the preview screen happens at most once
  /// per app launch — coming BACK from the preview shouldn't bounce the
  /// user straight into it again.
  bool _autoOpenedActiveRender = false;

  late final void Function(Object) _taskDataCallback;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _addRow();
    _preloadDesigns();
    _maybeRestoreTypedRows();
    // A render can finish while the user sits on THIS screen (they backed
    // out of the preview to start typing the next order). No lifecycle
    // transition happens then, so without this listener the ringtone would
    // loop until they backgrounded the app.
    _taskDataCallback = _onBackgroundTaskData;
    FlutterForegroundTask.addTaskDataCallback(_taskDataCallback);
    // Cold start with the "order ready" ringtone still looping (finished
    // while the app was closed) — silence it now that the user is here.
    // Visibility-gated: Android can also recreate this activity in the
    // BACKGROUND (e.g. after a config change), and that must not mute.
    muteOrderAlarmIfVisible();
    // Battery-exemption prompt runs AFTER the active-render check so its
    // dialog can't fight with the auto-opened preview route.
    _checkForActiveRender(autoOpen: true)
        .then((_) => _ensureBatteryExemption());
  }

  void _onBackgroundTaskData(Object data) {
    if (data is! Map) return;
    if (data['phase'] == 'prefetch') {
      final current = (data['current'] as int?) ?? 0;
      final total = (data['total'] as int?) ?? 0;
      if (mounted) {
        setState(() {
          _prefetchDone = current;
          _prefetchTotal = current >= total ? 0 : total;
          _prefetchLabel = (data['label'] as String?) ?? '';
        });
      }
      return;
    }
    if (data['phase'] == 'complete') {
      // NO mute — see THE RINGTONE ACKNOWLEDGEMENT LAW in order_alarm.dart.
      // This event is automatic and fires the instant the ring starts;
      // muting on it (even visibility-gated) silenced the ring every time
      // the user was in the app. Record it so the next tap/resume mutes.
      markOrderAlarmRinging();
    }
    if (data['phase'] == 'complete' || data['phase'] == 'error') {
      _checkForActiveRender(); // surfaces the "view current order" icon
    }
  }

  /// After a process restart, the typed rows are gone from memory but the
  /// last Continue's rows are still on disk. If the screen is empty,
  /// bring them back so the user never retypes an order.
  Future<void> _maybeRestoreTypedRows() async {
    final allEmpty = _rows.every((r) =>
        r.designController.text.trim().isEmpty &&
        r.qtyController.text.trim().isEmpty);
    if (!allEmpty) return;
    await _restoreRowsFromSaved();
  }

  /// ColorOS (Realme) kills background work far more aggressively than
  /// stock Android. Getting on the battery-optimization ignore list is the
  /// single biggest thing we can request programmatically to keep long
  /// renders alive with the screen off.
  Future<void> _ensureBatteryExemption() async {
    try {
      // Don't stack this dialog on top of the auto-opened preview screen —
      // it'll simply ask again on the next quiet launch.
      if (_autoOpenedActiveRender) return;
      if (await FlutterForegroundTask.isIgnoringBatteryOptimizations) return;
      if (!mounted) return;
      final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          icon: const Icon(Icons.battery_saver),
          title: const Text('Allow background work'),
          content: const Text(
            'To render big orders with the screen off, the phone must not '
            'put this app to sleep.\n\nOn the next dialog tap "Allow".',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: const Text('Later'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(ctx).pop(true),
              child: const Text('Continue'),
            ),
          ],
        ),
      );
      if (ok == true) {
        await FlutterForegroundTask.requestIgnoreBatteryOptimization();
      }
    } catch (_) {/* non-critical — worst case Realme stays aggressive */}
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _checkForActiveRender();
      // Silence the "order ready" looping ringtone now that the user has
      // the app open.
      muteOrderAlarm();
    }
  }

  @override
  void dispose() {
    FlutterForegroundTask.removeTaskDataCallback(_taskDataCallback);
    WidgetsBinding.instance.removeObserver(this);
    for (final r in _rows) {
      r.dispose();
    }
    super.dispose();
  }

  /// Detect whether a background render kicked off in a previous app
  /// session is still in flight (or already finished and waiting to be
  /// picked up). We just set a flag here; the banner in the build()
  /// gives the user a button to navigate to the preview screen.
  /// Doing a silent auto-push at startup was hanging some devices on
  /// the splash screen, so this is the safer cold-start UX.
  Future<void> _checkForActiveRender({bool autoOpen = false}) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      // The background isolate's writes don't auto-sync into our prefs
      // cache — reload before reading.
      await prefs.reload();
      final active = prefs.getString(OrderRenderConstants.activeOrderResultPrefKey) ?? '';
      final completed = prefs.getString(OrderRenderConstants.lastRenderPrefKey) ?? '';
      if (!mounted) return;
      setState(() => _hasActiveRender = active.isNotEmpty || completed.isNotEmpty);
      // App launch with an order in flight (or finished, waiting to send)
      // → jump straight to the Preview & Send screen. No banner, no tap.
      if (autoOpen && _hasActiveRender && !_autoOpenedActiveRender) {
        _autoOpenedActiveRender = true;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) _openActiveRender();
        });
      }
    } catch (_) {
      // Don't block UI if prefs fail to load — worst case the user
      // navigates to the order manually.
    }
  }

  Future<void> _openActiveRender() async {
    if (!mounted) return;
    final prefs = await SharedPreferences.getInstance();
    await prefs.reload();
    final stored = prefs.getString(OrderRenderConstants.activeOrderResultPrefKey) ?? '';
    if (stored.isEmpty) {
      setState(() => _hasActiveRender = false);
      return;
    }
    try {
      final data = jsonDecode(stored) as Map<String, dynamic>;
      final result = packingResultFromJson(data);
      if (!mounted) return;
      final outcome = await Navigator.of(context).push<PreviewResult>(MaterialPageRoute(
        builder: (_) => PreviewScreen(
          result: result,
          settings: widget.settings,
          designLibrary: widget.designLibrary,
        ),
      ));
      if (!mounted) return;
      if (outcome == PreviewResult.sent) {
        _clearOrder();
      } else if (outcome == PreviewResult.edited) {
        await _restoreRowsFromSaved();
      }
      await _checkForActiveRender();
    } catch (_) {
      await prefs.remove(OrderRenderConstants.activeOrderResultPrefKey);
      if (mounted) setState(() => _hasActiveRender = false);
    }
  }

  int _loadedSoFar = 0;
  bool _refreshingInBackground = false;

  Future<void> _preloadDesigns() async {
    final folder = widget.settings.oneDriveFolder;
    if (folder.isEmpty) return;

    // Already loaded in this session?
    if (widget.designLibrary.isLoadedFor(folder)) {
      setState(() => _designCount = widget.designLibrary.cachedIds(folder)!.length);
      return;
    }

    // Load from the on-disk cache only — no automatic network refresh. The
    // user explicitly asked that opening the app should NOT block on a
    // refresh; they'll tap the refresh icon in the design-count bar when
    // they want to pull new designs from OneDrive.
    final hadDiskCache = await widget.designLibrary.tryLoadFromDisk(folder);
    if (hadDiskCache && mounted) {
      setState(() {
        _designCount = widget.designLibrary.cachedIds(folder)!.length;
        _refreshingInBackground = false;
      });
      return;
    }

    // No disk cache — first-ever launch / fresh install. Have to do the
    // initial network load once so the autocomplete has something to show.
    setState(() {
      _loadingDesigns = true;
      _designLoadError = null;
      _loadedSoFar = 0;
    });
    await _refreshFromNetwork(folder, silent: false);
  }

  Future<void> _refreshFromNetwork(String folder, {required bool silent}) async {
    widget.designLibrary.onLoadProgress = silent
        ? null
        : (n) {
            if (!mounted) return;
            setState(() => _loadedSoFar = n);
          };
    try {
      // Force refresh: bypass in-memory cache to get fresh list
      final ids = await widget.designLibrary.refresh(folder).then(
            (entries) => entries.map((e) => e.designId).toList(),
          );
      if (!mounted) return;
      setState(() {
        _designCount = ids.length;
        _loadingDesigns = false;
        _refreshingInBackground = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loadingDesigns = false;
        _refreshingInBackground = false;
        if (!silent) _designLoadError = e.toString();
      });
    } finally {
      widget.designLibrary.onLoadProgress = null;
    }
  }

  void _addRow() => setState(() => _rows.add(_OrderRowController()));

  /// Quantity keypad's action key: hop to the NEXT row's Design # field —
  /// creating the row first when this was the last one — so a whole order
  /// can be typed without ever touching "Add another design".
  void _qtyDone(_OrderRowController row) {
    final idx = _rows.indexOf(row);
    if (idx < 0) return;
    if (idx == _rows.length - 1) _addRow();
    // The new row's field must be built before it can take focus.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (idx + 1 >= _rows.length) return;
      final next = _rows[idx + 1];
      try {
        if (next.designFocusNode.context != null) {
          next.designFocusNode.requestFocus();
        }
      } catch (_) {/* row removed meanwhile — ignore */}
    });
  }

  void _removeRow(_OrderRowController row) {
    if (_rows.length == 1) return;
    setState(() {
      row.dispose();
      _rows.remove(row);
    });
  }

  List<OrderLine> _collectLines() => _rows
      .map((r) => OrderLine(
            designId: r.designController.text.trim(),
            quantity: int.tryParse(r.qtyController.text.trim()) ?? 0,
          ))
      .where((l) => l.designId.isNotEmpty && l.quantity > 0)
      .toList();

  /// True if a row has a design typed but no valid quantity. Used to paint
  /// the quantity field red and to block Continue.
  bool _rowQtyMissing(_OrderRowController r) {
    final hasDesign = r.designController.text.trim().isNotEmpty;
    final qty = int.tryParse(r.qtyController.text.trim()) ?? 0;
    return hasDesign && qty <= 0;
  }

  /// Whether Continue should be enabled: at least one fully-filled row,
  /// and no started-but-missing-qty rows.
  bool get _canContinue {
    final anyError = _rows.any(_rowQtyMissing);
    if (anyError) return false;
    return _rows.any((r) =>
        r.designController.text.trim().isNotEmpty &&
        (int.tryParse(r.qtyController.text.trim()) ?? 0) > 0);
  }

  Future<void> _generate() async {
    final lines = _collectLines();
    if (lines.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Add at least one design with quantity > 0')),
      );
      return;
    }
    final result = Packer.pack(lines);
    // Persist the typed rows so Edit can restore them even if Android
    // recreates the activity while the background render runs.
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _kEnteredOrderLinesPref,
      jsonEncode(
          lines.map((l) => {'id': l.designId, 'qty': l.quantity}).toList()),
    );
    if (!mounted) return;
    final outcome = await Navigator.of(context).push<PreviewResult>(MaterialPageRoute(
      builder: (_) => PreviewScreen(
        result: result,
        settings: widget.settings,
        designLibrary: widget.designLibrary,
        freshRender: true, // user just tapped Continue → wipe stale cache
      ),
    ));
    if (!mounted) return;
    if (outcome == PreviewResult.sent) {
      _clearOrder();
    } else if (outcome == PreviewResult.edited) {
      await _restoreRowsFromSaved();
    }
    // PreviewResult.cancelled or null → leave rows alone.
    await _checkForActiveRender();
  }

  /// Rebuilds the order rows from the JSON saved at the last Continue.
  /// Source of truth for Edit — works whether or not the original
  /// activity (and its TextEditingControllers) survived.
  Future<void> _restoreRowsFromSaved() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_kEnteredOrderLinesPref) ?? '';
      if (raw.isEmpty) return;
      final list = (jsonDecode(raw) as List).cast<Map<String, dynamic>>();
      if (list.isEmpty || !mounted) return;
      setState(() {
        for (final r in _rows) {
          r.dispose();
        }
        _rows.clear();
        for (final m in list) {
          final c = _OrderRowController();
          c.designController.text = m['id'] as String;
          c.qtyController.text = '${m['qty']}';
          _rows.add(c);
        }
      });
    } catch (_) {/* corrupt blob — user just retypes */}
  }

  /// AppBar clear button: one confirmation tap guards against wiping a
  /// half-typed 40-design order by accident.
  Future<void> _confirmClearOrder() async {
    final hasAnything = _rows.any((r) =>
        r.designController.text.trim().isNotEmpty ||
        r.qtyController.text.trim().isNotEmpty);
    if (!hasAnything) return; // nothing to clear — don't even ask
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Clear order?'),
        content: const Text(
            'All design numbers and quantities below will be removed.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Clear'),
          ),
        ],
      ),
    );
    if (ok == true && mounted) _clearOrder();
  }

  /// Reset the form to a single empty row so user can immediately enter the
  /// next order without manually deleting old entries.
  void _clearOrder() {
    for (final r in _rows) {
      r.dispose();
    }
    setState(() {
      _rows.clear();
      _rows.add(_OrderRowController());
    });
    // The order is done — drop the saved rows so Edit on a future order
    // can't resurrect this one.
    SharedPreferences.getInstance()
        .then((p) => p.remove(_kEnteredOrderLinesPref));
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Order cleared - ready for next one'),
        duration: Duration(seconds: 2),
      ),
    );
  }

  /// Ask the service to (re-)check OneDrive for new designs right now.
  void _forcePrefetchNow() {
    try {
      FlutterForegroundTask.sendDataToTask({
        OrderRenderConstants.actionKey: OrderRenderConstants.actionPrefetch,
      });
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('Checking OneDrive for new designs…'),
        duration: Duration(seconds: 2),
      ));
    } catch (_) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('Background service is not running'),
      ));
    }
  }

  /// Rings the actual completion alarm via the background service — the
  /// exact code path a finished order uses — so "does the ringtone work?"
  /// can be answered in two seconds instead of after a full render.
  Future<void> _testRingtone() async {
    try {
      FlutterForegroundTask.sendDataToTask({
        OrderRenderConstants.actionKey: OrderRenderConstants.actionTestRing,
      });
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Background service is not running'),
        ));
      }
      return;
    }
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        icon: const Icon(Icons.notifications_active),
        title: const Text('Ringtone test'),
        content: const Text(
          'The order-ready ringtone should be playing at full volume right '
          'now — even in silent mode.\n\nIf you hear nothing, the phone is '
          'blocking the app\'s alarm sound.',
        ),
        actions: [
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Stop ringing'),
          ),
        ],
      ),
    );
    // However the dialog closed, the test is over — silence it.
    muteOrderAlarm();
  }

  Future<void> _openSettings() async {
    // Password gate: if a settings password is set, require it (or the
    // master reset code) before opening Settings. Leaves Settings reachable
    // when no password has been set yet, so the user can configure one.
    final required = widget.settings.settingsPassword;
    if (required.isNotEmpty) {
      final ok = await promptForPassword(
        context: context,
        expected: required,
        title: 'Enter settings password',
        description: 'A password is required to open Settings.',
        continueLabel: 'Open',
      );
      if (ok != true) return;
    }
    if (!mounted) return;
    await Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => SettingsScreen(settings: widget.settings, designLibrary: widget.designLibrary),
    ));
    if (mounted) _preloadDesigns();
  }

  @override
  Widget build(BuildContext context) {
    final preview = Packer.pack(_collectLines());
    final folder = widget.settings.oneDriveFolder;
    final knownIds = widget.designLibrary.cachedIds(folder) ?? const <String>[];
    return Scaffold(
      appBar: AppBar(
        // Hidden diagnostic: long-press the title to hear the REAL
        // order-ready ringtone path (full volume, silent-mode-proof).
        title: GestureDetector(
          onLongPress: _testRingtone,
          child: const Text('New Order'),
        ),
        actions: [
          // Quiet way back into an in-flight/finished order after the user
          // backed out of the preview (auto-open only fires once per launch).
          if (_hasActiveRender)
            IconButton(
              icon: const Icon(Icons.pending_actions),
              tooltip: 'View current order',
              onPressed: _openActiveRender,
            ),
          TextButton(
            onPressed: _confirmClearOrder,
            child: const Text(
              'CLEAR',
              style: TextStyle(fontWeight: FontWeight.w600),
            ),
          ),
          IconButton(icon: const Icon(Icons.settings), onPressed: _openSettings),
        ],
      ),
      body: Column(
        children: [
          if (_loadingDesigns) ...[
            const LinearProgressIndicator(minHeight: 2),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
              color: Theme.of(context).colorScheme.primaryContainer.withValues(alpha: 0.3),
              child: Row(
                children: [
                  const Icon(Icons.cloud_download, size: 14),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      _loadedSoFar > 0
                          ? 'Loading designs from OneDrive… $_loadedSoFar so far'
                          : 'Loading designs from OneDrive…',
                      style: const TextStyle(fontSize: 12),
                    ),
                  ),
                ],
              ),
            ),
          ],
          if (_prefetchTotal > 0) ...[
            LinearProgressIndicator(
              minHeight: 2,
              value: _prefetchDone / _prefetchTotal,
            ),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
              color: Theme.of(context)
                  .colorScheme
                  .secondaryContainer
                  .withValues(alpha: 0.3),
              child: Row(
                children: [
                  const Icon(Icons.download, size: 14),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      'Downloading new designs… '
                      '$_prefetchDone/$_prefetchTotal'
                      '${_prefetchLabel.isEmpty ? '' : '  ($_prefetchLabel)'}',
                      style: const TextStyle(fontSize: 12),
                    ),
                  ),
                  // Re-check OneDrive right now — pictures added after this
                  // pass started get queued immediately.
                  InkWell(
                    onTap: _forcePrefetchNow,
                    borderRadius: BorderRadius.circular(12),
                    child: const Padding(
                      padding: EdgeInsets.all(4),
                      child: Icon(Icons.refresh, size: 16),
                    ),
                  ),
                ],
              ),
            ),
          ],
          if (_designLoadError != null) _DesignErrorBar(error: _designLoadError!, onRetry: _preloadDesigns),
          if (!_loadingDesigns && _designLoadError == null && _designCount > 0)
            _DesignCountBar(
              count: _designCount,
              backgroundRefreshing: _refreshingInBackground,
              onRefresh: () async {
                // Grab the messenger BEFORE the await — using context
                // afterwards is unsafe if the screen goes away mid-refresh.
                final messenger = ScaffoldMessenger.of(context);
                setState(() => _loadingDesigns = true);
                try {
                  final entries = await widget.designLibrary.refresh(folder);
                  if (mounted) {
                    setState(() => _designCount = entries.length);
                  }
                  // List is fresh — now have the service pull down any new
                  // or changed design pictures so orders never wait on
                  // downloads. Progress arrives as 'prefetch' task-data.
                  try {
                    FlutterForegroundTask.sendDataToTask({
                      OrderRenderConstants.actionKey:
                          OrderRenderConstants.actionPrefetch,
                    });
                  } catch (_) {/* service down — next sync catches up */}
                  messenger.showSnackBar(
                    SnackBar(
                      content: Text('Refreshed — ${entries.length} designs'),
                      duration: const Duration(seconds: 2),
                    ),
                  );
                } catch (e) {
                  messenger.showSnackBar(
                    SnackBar(content: Text('Refresh failed: $e')),
                  );
                } finally {
                  if (mounted) setState(() => _loadingDesigns = false);
                }
              },
            ),
          Expanded(
            child: ListView.builder(
              padding: const EdgeInsets.all(16),
              itemCount: _rows.length + 1,
              itemBuilder: (context, i) {
                if (i == _rows.length) {
                  return Padding(
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    child: OutlinedButton.icon(
                      onPressed: _addRow,
                      icon: const Icon(Icons.add),
                      label: const Text('Add another design'),
                    ),
                  );
                }
                final row = _rows[i];
                return _OrderLineRow(
                  controller: row,
                  knownIds: knownIds,
                  designLibrary: widget.designLibrary,
                  qtyMissing: _rowQtyMissing(row),
                  onChanged: () => setState(() {}),
                  onQtyDone: () => _qtyDone(row),
                  onRemove: _rows.length > 1 ? () => _removeRow(row) : null,
                );
              },
            ),
          ),
          _SummaryBar(
            result: preview,
            onGenerate: _generate,
            canContinue: _canContinue,
          ),
        ],
      ),
    );
  }
}

class _OrderRowController {
  final TextEditingController designController = TextEditingController();
  final TextEditingController qtyController = TextEditingController();
  final FocusNode designFocusNode = FocusNode();
  final FocusNode qtyFocusNode = FocusNode();

  /// Design IDs are mostly numeric (5257, 6172…), so the Design # field
  /// opens the number pad by default. The in-field ABC/123 button flips
  /// this for letter-suffixed IDs like 1444A.
  bool numericDesignKeyboard = true;

  void dispose() {
    designController.dispose();
    qtyController.dispose();
    designFocusNode.dispose();
    qtyFocusNode.dispose();
  }
}

/// Strips spaces, dashes, underscores, and any non-alphanumeric character.
/// Used so users can type `1444A` and match files named `1444-A`, `1444 A`, etc.
String _normalizeId(String s) =>
    s.replaceAll(RegExp(r'[^a-zA-Z0-9]'), '').toLowerCase();

/// "1444 (B)" -> "1444": strips the extra-photo suffix so every picture of
/// one design number groups into a single swipeable preview.
String _baseDesignId(String s) =>
    _normalizeId(s.replaceAll(RegExp(r'\s*\([^)]*\)\s*$'), ''));

class _OrderLineRow extends StatelessWidget {
  final _OrderRowController controller;
  final List<String> knownIds;
  final DesignLibrary designLibrary;
  final bool qtyMissing;
  final VoidCallback onChanged;
  final VoidCallback? onRemove;
  final VoidCallback onQtyDone;

  const _OrderLineRow({
    required this.controller,
    required this.knownIds,
    required this.designLibrary,
    required this.qtyMissing,
    required this.onChanged,
    required this.onQtyDone,
    this.onRemove,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          Expanded(
            flex: 3,
            child: RawAutocomplete<String>(
              textEditingController: controller.designController,
              focusNode: controller.designFocusNode,
              optionsBuilder: (TextEditingValue value) {
                final query = _normalizeId(value.text);
                if (query.isEmpty || knownIds.isEmpty) return const Iterable<String>.empty();
                // Prefix match (not substring): typing "5258" finds "5258A"
                // but NOT "35258".
                return knownIds.where((id) => _normalizeId(id).startsWith(query));
              },
              onSelected: (String selection) {
                controller.designController.text = selection;
                controller.designFocusNode.unfocus();
                // The preview dialog restores focus to the design field as
                // it pops (reopening the dropdown, no keypad). A microtask
                // fires too early to win that fight — wait for the pop
                // animation to finish, THEN claim focus for Quantity so
                // the number pad opens there directly.
                Future.delayed(const Duration(milliseconds: 300), () {
                  try {
                    if (controller.qtyFocusNode.context != null) {
                      controller.qtyFocusNode.requestFocus();
                    }
                  } catch (_) {/* row removed meanwhile — ignore */}
                });
                onChanged();
              },
              fieldViewBuilder: (ctx, textEditingController, focusNode, onFieldSubmitted) {
                final numeric = controller.numericDesignKeyboard;
                return TextField(
                  controller: textEditingController,
                  focusNode: focusNode,
                  // Number pad by default (design IDs are mostly digits).
                  // The suffix button flips to a full keyboard for IDs
                  // with letter suffixes (1444A). visiblePassword gives a
                  // QWERTY layout with the digit row and no autocorrect.
                  keyboardType: numeric
                      ? TextInputType.number
                      : TextInputType.visiblePassword,
                  autocorrect: false,
                  enableSuggestions: false,
                  decoration: InputDecoration(
                    labelText: 'Design #',
                    border: const OutlineInputBorder(),
                    hintText: knownIds.isEmpty ? 'e.g. 1444 or 1333A' : 'type to search…',
                    suffixIcon: TextButton(
                      style: TextButton.styleFrom(
                        minimumSize: const Size(40, 36),
                        padding: const EdgeInsets.symmetric(horizontal: 8),
                      ),
                      onPressed: () {
                        controller.numericDesignKeyboard = !numeric;
                        // The IME only re-reads keyboardType on refocus —
                        // bounce focus so the new keyboard appears at once.
                        focusNode.unfocus();
                        Future.delayed(const Duration(milliseconds: 60), () {
                          // Row may have been removed/cleared during the
                          // delay — a disposed FocusNode must not be used.
                          try {
                            if (focusNode.context != null) {
                              focusNode.requestFocus();
                            }
                          } catch (_) {/* disposed — ignore */}
                        });
                        onChanged();
                      },
                      child: Text(
                        numeric ? 'ABC' : '123',
                        style: const TextStyle(
                            fontWeight: FontWeight.w700, fontSize: 13),
                      ),
                    ),
                  ),
                  textCapitalization: TextCapitalization.characters,
                  onChanged: (_) => onChanged(),
                  onSubmitted: (_) => onFieldSubmitted(),
                );
              },
              optionsViewBuilder: (ctx, onSelected, options) {
                return Align(
                  alignment: Alignment.topLeft,
                  child: Material(
                    elevation: 4,
                    borderRadius: BorderRadius.circular(8),
                    child: ConstrainedBox(
                      constraints: BoxConstraints(
                        maxHeight: MediaQuery.of(ctx).size.height * 0.6,
                        maxWidth: 340,
                      ),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          if (options.length > 50)
                            Container(
                              width: double.infinity,
                              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                              color: Theme.of(ctx)
                                  .colorScheme
                                  .surfaceContainerHighest,
                              child: Text(
                                '${options.length} matches  · scroll to see more',
                                style: const TextStyle(fontSize: 11),
                              ),
                            ),
                          Flexible(
                            child: ListView.builder(
                              padding: EdgeInsets.zero,
                              shrinkWrap: true,
                              itemCount: options.length,
                              itemBuilder: (_, i) {
                                final option = options.elementAt(i);
                                // Every photo of this design number ("1444",
                                // "1444 (A)", …) — the preview swipes
                                // through them all.
                                final base = _baseDesignId(option);
                                final siblings = knownIds
                                    .where((k) => _baseDesignId(k) == base)
                                    .toList()
                                  ..sort();
                                return _DesignOption(
                                  designId: option,
                                  siblings: siblings,
                                  designLibrary: designLibrary,
                                  onSelect: onSelected,
                                );
                              },
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            flex: 2,
            child: TextField(
              controller: controller.qtyController,
              focusNode: controller.qtyFocusNode,
              decoration: InputDecoration(
                labelText: 'Quantity',
                border: const OutlineInputBorder(),
                // Red outline + label when a design has been typed but
                // quantity is empty/zero. Disables the Continue button
                // upstream as well.
                enabledBorder: qtyMissing
                    ? const OutlineInputBorder(
                        borderSide: BorderSide(color: Colors.red, width: 2),
                      )
                    : null,
                focusedBorder: qtyMissing
                    ? const OutlineInputBorder(
                        borderSide: BorderSide(color: Colors.red, width: 2),
                      )
                    : null,
                labelStyle:
                    qtyMissing ? const TextStyle(color: Colors.red) : null,
                errorText: qtyMissing ? 'Required' : null,
              ),
              keyboardType: TextInputType.number,
              // "Next"-style action key instead of the tick: pressing it
              // jumps straight to the next row's Design # field (adding
              // the row if needed) for non-stop order typing.
              textInputAction: TextInputAction.next,
              onChanged: (_) => onChanged(),
              onSubmitted: (_) => onQtyDone(),
            ),
          ),
          if (onRemove != null)
            IconButton(
              icon: const Icon(Icons.close),
              tooltip: 'Remove this design',
              onPressed: onRemove,
            ),
        ],
      ),
    );
  }
}

class _DesignOption extends StatelessWidget {
  final String designId;
  final List<String> siblings;
  final DesignLibrary designLibrary;
  final ValueChanged<String> onSelect;
  const _DesignOption({
    required this.designId,
    required this.siblings,
    required this.designLibrary,
    required this.onSelect,
  });

  Future<void> _confirmAndSelect(BuildContext ctx) async {
    // The dialog returns the photo the user was LOOKING at when they hit
    // OK — swiping to "1444 (B)" and confirming selects "1444 (B)".
    final chosen = await showDialog<String>(
      context: ctx,
      builder: (dialogCtx) => _DesignPreviewDialog(
        designId: designId,
        siblings: siblings.isEmpty ? [designId] : siblings,
        designLibrary: designLibrary,
      ),
    );
    if (chosen != null) onSelect(chosen);
  }

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: () => _confirmAndSelect(context),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: Row(
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: SizedBox(
                width: 40,
                height: 60,
                // Local-first: the prefetched design file opens instantly
                // (cacheWidth keeps the decoded bitmap tiny); only designs
                // not on the phone yet fall back to OneDrive thumbnails.
                child: FutureBuilder<File?>(
                  future: designLibrary.getCachedDesignFile(designId),
                  builder: (ctx, snap) {
                    if (snap.connectionState == ConnectionState.waiting) {
                      return Container(color: Colors.grey.shade200);
                    }
                    final local = snap.data;
                    if (local != null) {
                      return Image.file(local,
                          fit: BoxFit.cover,
                          gaplessPlayback: true,
                          cacheWidth: 120);
                    }
                    return FutureBuilder(
                      future:
                          designLibrary.getThumbnail(designId, size: 'small'),
                      builder: (ctx, snap) {
                        if (snap.connectionState == ConnectionState.waiting) {
                          return Container(
                            color: Colors.grey.shade200,
                            child: const Center(
                              child: SizedBox(
                                width: 14,
                                height: 14,
                                child:
                                    CircularProgressIndicator(strokeWidth: 2),
                              ),
                            ),
                          );
                        }
                        final bytes = snap.data;
                        if (bytes == null) {
                          return Container(
                            color: Colors.grey.shade200,
                            child: const Icon(Icons.image_not_supported,
                                size: 18, color: Colors.grey),
                          );
                        }
                        return Image.memory(bytes,
                            fit: BoxFit.cover, gaplessPlayback: true);
                      },
                    );
                  },
                ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                designId,
                style: const TextStyle(fontWeight: FontWeight.w500),
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _DesignPreviewDialog extends StatefulWidget {
  final String designId;
  final List<String> siblings;
  final DesignLibrary designLibrary;
  const _DesignPreviewDialog({
    required this.designId,
    required this.siblings,
    required this.designLibrary,
  });

  @override
  State<_DesignPreviewDialog> createState() => _DesignPreviewDialogState();
}

class _DesignPreviewDialogState extends State<_DesignPreviewDialog> {
  late int _current =
      widget.siblings.indexOf(widget.designId).clamp(0, widget.siblings.length - 1);
  late final PageController _pageController =
      PageController(initialPage: _current);

  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
  }

  /// Local-first: the downloaded print file itself, shown instantly
  /// (decoded at ~900 px wide — dialog-sharp without holding the full
  /// 2100x3150 bitmap). Not-yet-downloaded designs fall back to the
  /// OneDrive 600×900 thumbnail.
  Widget _photo(String id) {
    return FutureBuilder<File?>(
      future: widget.designLibrary.getCachedDesignFile(id),
      builder: (ctx, snap) {
        if (snap.connectionState == ConnectionState.waiting) {
          return Container(color: Colors.grey.shade100);
        }
        final local = snap.data;
        if (local != null) {
          return Image.file(local,
              fit: BoxFit.contain, gaplessPlayback: true, cacheWidth: 900);
        }
        return FutureBuilder(
          future: widget.designLibrary.getThumbnail(id, size: 'c600x900'),
          builder: (ctx, snap) {
            if (snap.connectionState == ConnectionState.waiting) {
              return Container(
                color: Colors.grey.shade100,
                child: const Center(child: CircularProgressIndicator()),
              );
            }
            final bytes = snap.data;
            if (bytes == null) {
              return Container(
                color: Colors.grey.shade100,
                child: const Center(
                  child: Icon(Icons.image_not_supported,
                      size: 48, color: Colors.grey),
                ),
              );
            }
            return Image.memory(bytes,
                fit: BoxFit.contain, gaplessPlayback: true);
          },
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final siblings = widget.siblings;
    final multi = siblings.length > 1;
    return AlertDialog(
      title: Text('Design ${siblings[_current]}'),
      contentPadding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
      content: SizedBox(
        width: 280,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 360, maxWidth: 280),
              child: AspectRatio(
                aspectRatio: 6 / 9,
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: PageView.builder(
                    controller: _pageController,
                    itemCount: siblings.length,
                    onPageChanged: (i) => setState(() => _current = i),
                    itemBuilder: (_, i) => _photo(siblings[i]),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 8),
            Text(
              multi
                  ? 'Photo ${_current + 1} of ${siblings.length} — swipe for more.'
                  : 'Confirm this is the right design.',
              style: const TextStyle(fontSize: 12),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(null),
          child: const Text('Cancel'),
        ),
        FilledButton(
          // Returns the photo currently on screen.
          onPressed: () => Navigator.of(context).pop(siblings[_current]),
          child: const Text('OK'),
        ),
      ],
    );
  }
}

class _DesignCountBar extends StatelessWidget {
  final int count;
  final bool backgroundRefreshing;
  final Future<void> Function() onRefresh;
  const _DesignCountBar({
    required this.count,
    required this.backgroundRefreshing,
    required this.onRefresh,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      color: Theme.of(context).colorScheme.primaryContainer.withValues(alpha: 0.3),
      child: Row(
        children: [
          if (backgroundRefreshing)
            const SizedBox(
              width: 14,
              height: 14,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          else
            const Icon(Icons.cloud_done, size: 14),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              backgroundRefreshing
                  ? '$count designs (refreshing in background…)'
                  : '$count designs from OneDrive',
              style: const TextStyle(fontSize: 12),
            ),
          ),
          IconButton(
            icon: const Icon(Icons.refresh, size: 18),
            tooltip: 'Reload from OneDrive',
            onPressed: onRefresh,
          ),
        ],
      ),
    );
  }
}

class _DesignErrorBar extends StatelessWidget {
  final String error;
  final VoidCallback onRetry;
  const _DesignErrorBar({required this.error, required this.onRetry});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      color: Colors.orange.shade50,
      child: Row(
        children: [
          Icon(Icons.warning_amber, size: 16, color: Colors.orange.shade700),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              'OneDrive: ${error.length > 80 ? "${error.substring(0, 80)}…" : error}',
              style: const TextStyle(fontSize: 11),
            ),
          ),
          TextButton(onPressed: onRetry, child: const Text('Retry')),
        ],
      ),
    );
  }
}

class _SummaryBar extends StatelessWidget {
  final PackingResult result;
  final VoidCallback onGenerate;
  final bool canContinue;
  const _SummaryBar({
    required this.result,
    required this.onGenerate,
    required this.canContinue,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      elevation: 8,
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceAround,
              children: [
                _stat('Prints', '${result.totalPrintsRequested}'),
                _stat('Sheets', '${result.totalSheetsToPrint}'),
                _stat('Extras', '${result.extras}'),
              ],
            ),
            const SizedBox(height: 12),
            FilledButton.icon(
              onPressed: canContinue ? onGenerate : null,
              icon: const Icon(Icons.auto_awesome),
              label: const Padding(
                padding: EdgeInsets.symmetric(vertical: 14),
                child: Text('Continue', style: TextStyle(fontSize: 16)),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _stat(String label, String value) {
    return Column(
      children: [
        Text(value, style: const TextStyle(fontSize: 22, fontWeight: FontWeight.bold)),
        Text(label, style: const TextStyle(fontSize: 12)),
      ],
    );
  }
}
