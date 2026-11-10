import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'services/gdrive_uploader.dart';

import 'screens/activation_screen.dart';
import 'screens/order_screen.dart';
import 'services/design_library.dart';
import 'services/onedrive_auth.dart';
import 'services/order_alarm.dart';
import 'services/order_render_task.dart';
import 'services/settings_store.dart';

Future<void> main() async {
  // Wrap startup in a guard so a silent exception during init can't leave
  // the app stuck on the Android splash screen forever — the user at
  // least sees the error and can restart.
  try {
    WidgetsFlutterBinding.ensureInitialized();
    // Foreground service comms must be wired up before the service can
    // push data back to the UI isolate. Safe to call on every launch,
    // including when the service is already running from a previous
    // process lifecycle.
    FlutterForegroundTask.initCommunicationPort();
    _initForegroundTask();
    final settings = await AppSettings.load();
    final auth = OneDriveAuth();
    final designLibrary = DesignLibrary(auth);
    runApp(PrintCollageApp(
      settings: settings,
      designLibrary: designLibrary,
    ));
    // Kick the persistent foreground service if it isn't already alive.
    // Fire-and-forget so a plugin-channel hiccup doesn't delay the first
    // frame.
    _ensureBackgroundServiceRunning().catchError((_) {});
    // Cache the bundled Google Drive service-account key into prefs so the
    // background isolate can read it without touching rootBundle.
    _cacheGdriveKey().catchError((_) {});
  } catch (e, st) {
    runApp(MaterialApp(
      home: Scaffold(
        body: SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('Print Collage Tool failed to start',
                      style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                  const SizedBox(height: 12),
                  SelectableText('$e\n\n$st',
                      style: const TextStyle(fontSize: 12)),
                ],
              ),
            ),
          ),
        ),
      ),
    ));
  }
}

void _initForegroundTask() {
  FlutterForegroundTask.init(
    androidNotificationOptions: AndroidNotificationOptions(
      channelId: OrderRenderConstants.notificationChannelId,
      channelName: OrderRenderConstants.notificationChannelName,
      channelDescription:
          'Keeps OneDrive auto-sync running and renders print orders in the background.',
      // LOW priority — visible in the status bar (so render progress
      // shows up live) but silent, so the always-on auto-sync icon
      // doesn't ping every 3 hours. MIN was hiding the notification
      // entirely on some Android versions.
      channelImportance: NotificationChannelImportance.LOW,
      priority: NotificationPriority.LOW,
    ),
    iosNotificationOptions: const IOSNotificationOptions(
      showNotification: true,
      playSound: false,
    ),
    foregroundTaskOptions: ForegroundTaskOptions(
      // 30 min periodic tick → the background isolate refreshes the
      // OneDrive design list every half hour. Adjust here if needed;
      // Android won't fire periodic events more often than ~15 min.
      eventAction: ForegroundTaskEventAction.repeat(30 * 60 * 1000),
      autoRunOnBoot: true,
      autoRunOnMyPackageReplaced: true,
      allowWakeLock: true,
      // Keep WiFi awake while the service runs — with the screen off,
      // Android's WiFi power-save was cutting connections mid-download
      // ("Software caused connection abort", errno 103), killing renders.
      allowWifiLock: true,
    ),
  );
}

/// Copy the bundled service-account JSON into SharedPreferences where the
/// background isolate (which uploads order ZIPs to Google Drive) can read
/// it. A placeholder `{}` asset means the feature is not configured yet —
/// the pipeline then falls back to plain email attachments.
Future<void> _cacheGdriveKey() async {
  final raw = await rootBundle.loadString('assets/gdrive_service_account.json');
  final prefs = await SharedPreferences.getInstance();
  await prefs.setString(kGdriveServiceAccountPrefKey, raw.trim());
}

/// Make sure the always-on foreground service is running so OneDrive
/// auto-sync ticks even when the user has the app closed.
Future<void> _ensureBackgroundServiceRunning() async {
  if (await FlutterForegroundTask.isRunningService) return;
  final permission = await FlutterForegroundTask.checkNotificationPermission();
  if (permission != NotificationPermission.granted) {
    await FlutterForegroundTask.requestNotificationPermission();
  }
  await FlutterForegroundTask.startService(
    serviceId: 421,
    // Minimal title/body — Android requires a notification for the
    // foreground service, but the user explicitly does not want it to
    // show sync progress. Only render-time updates change this text.
    notificationTitle: 'Print Collage Tool',
    notificationText: '',
    callback: orderRenderTaskEntryPoint,
  );
}

class PrintCollageApp extends StatefulWidget {
  final AppSettings settings;
  final DesignLibrary designLibrary;
  const PrintCollageApp({
    super.key,
    required this.settings,
    required this.designLibrary,
  });

  @override
  State<PrintCollageApp> createState() => _PrintCollageAppState();
}

class _PrintCollageAppState extends State<PrintCollageApp> {
  late bool _activated;

  @override
  void initState() {
    super.initState();
    _activated = widget.settings.isActivated;
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Print Collage Tool',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF1E5AA8)),
        useMaterial3: true,
      ),
      // Any screen touch acknowledges (and silences) the order-ready
      // ringtone — see THE RINGTONE ACKNOWLEDGEMENT LAW in order_alarm.dart.
      // Translucent so it never swallows the tap it observes.
      builder: (context, child) => Listener(
        behavior: HitTestBehavior.translucent,
        onPointerDown: (_) => muteOrderAlarmIfRinging(),
        child: child ?? const SizedBox.shrink(),
      ),
      // First-launch activation gate. Until the user enters the master
      // code, OrderScreen is unreachable — so just copying the APK to
      // another phone does not give someone a working install.
      home: _activated
          ? OrderScreen(settings: widget.settings, designLibrary: widget.designLibrary)
          : ActivationScreen(
              settings: widget.settings,
              onActivated: () => setState(() => _activated = true),
            ),
    );
  }
}
