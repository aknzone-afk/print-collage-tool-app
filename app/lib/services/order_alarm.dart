import 'package:flutter/widgets.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';

import 'order_render_task.dart';

/// ==================== THE RINGTONE ACKNOWLEDGEMENT LAW ====================
/// The order-ready ringtone stops ONLY on a genuine user action:
///   1. the app is cold-opened while visible,
///   2. the app transitions to resumed (unlock / brought to foreground),
///   3. the user taps anywhere while it is ringing.
/// It must NEVER be stopped by an automatic event. The 'complete' task-data
/// message is NOT a user action — it fires the instant the render finishes,
/// and if the user is sitting in the app watching progress (the normal
/// case!), muting on it kills the ring within milliseconds of it starting.
/// That exact bug shipped three times. Do not reintroduce it.
/// =========================================================================

/// True while (we believe) the service-side looping ringtone is sounding.
/// Set when a 'complete' event arrives; cleared by any mute.
bool _alarmRinging = false;

/// Record that the service just started the order-ready ringtone.
/// Called from 'complete' task-data handlers INSTEAD of muting.
void markOrderAlarmRinging() => _alarmRinging = true;

/// True only when the app is actually on-screen.
///
/// CRITICAL: task-data events from the background isolate are delivered to
/// the UI isolate even while the app is backgrounded or the phone is
/// locked — the Flutter engine stays alive. So "we received a progress
/// event" does NOT mean the user can see anything.
///
/// lifecycleState is null for a moment during cold start; the user is
/// opening the app in that case, so null counts as visible.
bool get appIsVisible {
  final state = WidgetsBinding.instance.lifecycleState;
  return state == null || state == AppLifecycleState.resumed;
}

/// Silence the looping "order ready" ringtone. Idempotent — the handler
/// ignores it when nothing is playing.
void muteOrderAlarm() {
  _alarmRinging = false;
  try {
    FlutterForegroundTask.sendDataToTask({
      OrderRenderConstants.actionKey: OrderRenderConstants.actionMute,
    });
  } catch (_) {/* service not up — nothing to mute */}
}

/// Mute only if the user can actually see the app. For the cold-start
/// acknowledgement path: Android can recreate the activity in the
/// BACKGROUND (config change), and that must not mute.
void muteOrderAlarmIfVisible() {
  if (appIsVisible) muteOrderAlarm();
}

/// Global tap hook (wired to a root Listener in main.dart): a screen touch
/// is an acknowledgement, so stop the ring — but only when it is actually
/// ringing, so everyday taps don't spam the service or clear its
/// notification text.
void muteOrderAlarmIfRinging() {
  if (_alarmRinging) muteOrderAlarm();
}
