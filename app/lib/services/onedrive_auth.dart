import 'dart:async';
import 'dart:convert';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;

import '../config.dart';

/// Holds the public info shown to the user during device-code sign-in
/// (the short code they type at https://microsoft.com/devicelogin on a PC).
class DeviceCodeChallenge {
  final String userCode;
  final String verificationUri;
  final String message;
  final Duration expiresIn;
  const DeviceCodeChallenge({
    required this.userCode,
    required this.verificationUri,
    required this.message,
    required this.expiresIn,
  });
}

class _DeviceCodeSession extends DeviceCodeChallenge {
  final String deviceCode;
  final Duration interval;
  _DeviceCodeSession({
    required this.deviceCode,
    required super.userCode,
    required super.verificationUri,
    required super.message,
    required super.expiresIn,
    required this.interval,
  });
}

class OneDriveAuth {
  static const _kAccessToken = 'msal_access_token';
  static const _kRefreshToken = 'msal_refresh_token';
  static const _kAccessExpiry = 'msal_access_expiry';

  final FlutterSecureStorage _storage = const FlutterSecureStorage();

  Future<bool> get isSignedIn async {
    final token = await _storage.read(key: _kRefreshToken);
    return token != null && token.isNotEmpty;
  }

  /// Ask Microsoft for a device-code challenge. Returns the user-facing code
  /// to display, then you must call [completeDeviceCodeSignIn] with the
  /// returned [DeviceCodeChallenge] to start polling for completion.
  Future<DeviceCodeChallenge> startDeviceCodeSignIn() async {
    if (!AzureConfig.isConfigured) {
      throw StateError('Azure client ID not configured.');
    }
    final res = await http.post(
      Uri.parse(AzureConfig.deviceCodeEndpoint),
      headers: {'Content-Type': 'application/x-www-form-urlencoded'},
      body: {
        'client_id': AzureConfig.azureClientId,
        'scope': AzureConfig.scopes.join(' '),
      },
    );
    if (res.statusCode != 200) {
      throw StateError('Device code request failed (HTTP ${res.statusCode}): ${res.body}');
    }
    final body = jsonDecode(res.body) as Map<String, dynamic>;
    final session = _DeviceCodeSession(
      deviceCode: body['device_code'] as String,
      userCode: body['user_code'] as String,
      verificationUri: body['verification_uri'] as String,
      message: body['message'] as String? ?? '',
      expiresIn: Duration(seconds: (body['expires_in'] as num).toInt()),
      interval: Duration(seconds: (body['interval'] as num?)?.toInt() ?? 5),
    );
    _activeSession = session;
    return session;
  }

  _DeviceCodeSession? _activeSession;

  /// Polls Microsoft until the user completes sign-in on their PC, the code
  /// expires, or the user denies access. Throws on failure / timeout.
  Future<String> completeDeviceCodeSignIn() async {
    final session = _activeSession;
    if (session == null) {
      throw StateError('No active device-code session. Call startDeviceCodeSignIn() first.');
    }
    final deadline = DateTime.now().add(session.expiresIn);
    while (DateTime.now().isBefore(deadline)) {
      await Future.delayed(session.interval);
      final res = await http.post(
        Uri.parse(AzureConfig.tokenEndpoint),
        headers: {'Content-Type': 'application/x-www-form-urlencoded'},
        body: {
          'grant_type': 'urn:ietf:params:oauth:grant-type:device_code',
          'client_id': AzureConfig.azureClientId,
          'device_code': session.deviceCode,
        },
      );
      final body = jsonDecode(res.body) as Map<String, dynamic>;
      if (res.statusCode == 200) {
        final access = body['access_token'] as String;
        final refresh = body['refresh_token'] as String?;
        final expiresIn = Duration(seconds: (body['expires_in'] as num).toInt());
        await _persist(access, refresh, DateTime.now().add(expiresIn));
        _activeSession = null;
        return access;
      }
      final error = body['error'] as String? ?? 'unknown_error';
      if (error == 'authorization_pending') {
        continue; // user hasn't entered code yet — keep polling
      }
      if (error == 'slow_down') {
        await Future.delayed(const Duration(seconds: 5));
        continue;
      }
      if (error == 'authorization_declined') {
        throw StateError('Sign-in declined. Try again.');
      }
      if (error == 'expired_token') {
        throw StateError('Code expired. Tap Sign in again to get a new code.');
      }
      throw StateError('Sign-in failed: ${body['error_description'] ?? error}');
    }
    throw StateError('Sign-in timed out. Tap Sign in again.');
  }

  Future<void> cancelDeviceCodeSignIn() async {
    _activeSession = null;
  }

  Future<void> signOut() async {
    await _storage.delete(key: _kAccessToken);
    await _storage.delete(key: _kRefreshToken);
    await _storage.delete(key: _kAccessExpiry);
    _activeSession = null;
  }

  Future<String> getAccessToken() async {
    final access = await _storage.read(key: _kAccessToken);
    final expiryString = await _storage.read(key: _kAccessExpiry);
    final expiry = expiryString != null ? DateTime.tryParse(expiryString) : null;
    if (access != null &&
        expiry != null &&
        expiry.isAfter(DateTime.now().add(const Duration(seconds: 60)))) {
      return access;
    }
    return _refresh();
  }

  Future<String> _refresh() async {
    final refresh = await _storage.read(key: _kRefreshToken);
    if (refresh == null || refresh.isEmpty) {
      throw StateError('Not signed in. Open Settings → Sign in to OneDrive.');
    }
    final res = await http.post(
      Uri.parse(AzureConfig.tokenEndpoint),
      headers: {'Content-Type': 'application/x-www-form-urlencoded'},
      body: {
        'grant_type': 'refresh_token',
        'client_id': AzureConfig.azureClientId,
        'refresh_token': refresh,
        'scope': AzureConfig.scopes.join(' '),
      },
    );
    if (res.statusCode != 200) {
      throw StateError('Token refresh failed (HTTP ${res.statusCode}): ${res.body}');
    }
    final body = jsonDecode(res.body) as Map<String, dynamic>;
    final access = body['access_token'] as String;
    final newRefresh = body['refresh_token'] as String? ?? refresh;
    final expiresIn = Duration(seconds: (body['expires_in'] as num).toInt());
    await _persist(access, newRefresh, DateTime.now().add(expiresIn));
    return access;
  }

  Future<void> _persist(String? access, String? refresh, DateTime? expiry) async {
    if (access != null) await _storage.write(key: _kAccessToken, value: access);
    if (refresh != null) await _storage.write(key: _kRefreshToken, value: refresh);
    if (expiry != null) await _storage.write(key: _kAccessExpiry, value: expiry.toIso8601String());
  }
}
