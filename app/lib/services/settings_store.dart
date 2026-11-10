import 'package:shared_preferences/shared_preferences.dart';

class AppSettings {
  static const _kEmail = 'destination_email';
  static const _kFolder = 'onedrive_folder';
  static const _kRoundUp = 'round_up_extras';
  static const _kSendPassword = 'send_password';
  static const _kSettingsPassword = 'settings_password';
  static const _kActivated = 'activated';

  final SharedPreferences _prefs;

  AppSettings._(this._prefs);

  static Future<AppSettings> load() async {
    final prefs = await SharedPreferences.getInstance();
    return AppSettings._(prefs);
  }

  String get destinationEmail => _prefs.getString(_kEmail) ?? '';
  Future<void> setDestinationEmail(String value) =>
      _prefs.setString(_kEmail, value.trim());

  /// Folder used by the order screen's design-ID autocomplete (the source
  /// of the 6x9 designs we collage into 12x18 sheets).
  String get oneDriveFolder => _prefs.getString(_kFolder) ?? '12 X 18';
  Future<void> setOneDriveFolder(String value) =>
      _prefs.setString(_kFolder, value.trim());

  bool get roundUpExtras => _prefs.getBool(_kRoundUp) ?? true;
  Future<void> setRoundUpExtras(bool value) => _prefs.setBool(_kRoundUp, value);

  /// Password required before the email app is opened to send a print order.
  /// Empty string = no password gate (default). Set in Settings to enforce
  /// a confirmation step on every send.
  String get sendPassword => _prefs.getString(_kSendPassword) ?? '';
  Future<void> setSendPassword(String value) =>
      _prefs.setString(_kSendPassword, value);

  /// Password required to open the Settings screen itself. Empty string =
  /// no gate. Set this to keep someone with the phone out of Settings.
  /// Both this and [sendPassword] can be bypassed with the fixed master
  /// reset code (see [kMasterResetCode] in services/password_prompt.dart).
  String get settingsPassword => _prefs.getString(_kSettingsPassword) ?? '';
  Future<void> setSettingsPassword(String value) =>
      _prefs.setString(_kSettingsPassword, value);

  bool get isReady => destinationEmail.isNotEmpty && oneDriveFolder.isNotEmpty;

  /// First-launch activation gate. Set to true once the user has typed
  /// the master activation code (see kMasterResetCode) on the first run
  /// after install. Persists in SharedPreferences so subsequent launches
  /// skip the prompt.
  bool get isActivated => _prefs.getBool(_kActivated) ?? false;
  Future<void> setActivated(bool value) =>
      _prefs.setBool(_kActivated, value);
}
