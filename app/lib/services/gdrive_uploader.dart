import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:googleapis_auth/auth_io.dart' as gauth;
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

/// SharedPreferences key where main() caches the service-account JSON from
/// the bundled asset. The background isolate reads it from prefs instead of
/// rootBundle so asset loading never has to work inside the service isolate.
const String kGdriveServiceAccountPrefKey = 'gdrive_service_account_json';

/// Uploads order ZIPs to Google Drive using a service account and returns a
/// link that is ALREADY shared as "anyone with the link can view" — the
/// recipient never sees a permission prompt.
///
/// Why a service account: no sign-in UI, no per-keystore OAuth client setup,
/// and the files live in the service account's own 15 GB Drive space —
/// separate from the user's Gmail storage. [_cleanupOldUploads] deletes
/// uploads older than 30 days so that space never fills up.
class GDriveUploader {
  static const _driveScope = 'https://www.googleapis.com/auth/drive.file';
  static const _apiBase = 'https://www.googleapis.com/drive/v3';
  static const _uploadBase = 'https://www.googleapis.com/upload/drive/v3';

  /// True when a real service-account key has been bundled (the placeholder
  /// asset is an empty JSON object).
  static Future<bool> isConfigured() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.reload();
    final raw = prefs.getString(kGdriveServiceAccountPrefKey) ?? '';
    if (raw.trim().isEmpty) return false;
    try {
      final json = jsonDecode(raw);
      return json is Map && json.containsKey('private_key');
    } catch (_) {
      return false;
    }
  }

  /// Uploads [zip] as [name], shares it anyone-with-link/viewer, and returns
  /// the view URL. Throws on hard failure; retries transient ones. Returns
  /// null when no service-account key is configured.
  static Future<String?> uploadAndShare(File zip, String name) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.reload();
    final raw = prefs.getString(kGdriveServiceAccountPrefKey) ?? '';
    if (raw.trim().isEmpty) return null;
    late final gauth.ServiceAccountCredentials creds;
    try {
      creds = gauth.ServiceAccountCredentials.fromJson(jsonDecode(raw));
    } catch (_) {
      return null; // placeholder / malformed key — feature not set up yet
    }

    const retryDelaysSeconds = [3, 8, 20];
    for (var attempt = 0;; attempt++) {
      gauth.AutoRefreshingAuthClient? client;
      try {
        client = await gauth.clientViaServiceAccount(creds, [_driveScope]);

        // 1. Start a resumable upload session.
        final startRes = await client.post(
          Uri.parse('$_uploadBase/files?uploadType=resumable&fields=id,webViewLink'),
          headers: {'Content-Type': 'application/json; charset=UTF-8'},
          body: jsonEncode({'name': name, 'mimeType': 'application/zip'}),
        );
        if (startRes.statusCode != 200) {
          throw HttpException(
              'Drive upload init failed (HTTP ${startRes.statusCode}): ${startRes.body}');
        }
        final sessionUrl = startRes.headers['location'];
        if (sessionUrl == null) {
          throw const HttpException('Drive upload init returned no session URL');
        }

        // 2. Stream the ZIP into the session — never load it all into RAM.
        final length = await zip.length();
        final put = http.StreamedRequest('PUT', Uri.parse(sessionUrl));
        put.contentLength = length;
        put.headers['Content-Type'] = 'application/zip';
        unawaited(zip
            .openRead()
            .forEach(put.sink.add)
            .then((_) => put.sink.close(), onError: put.sink.addError));
        final uploadRes = await client
            .send(put)
            .timeout(const Duration(minutes: 15));
        final uploadBody = await uploadRes.stream.bytesToString();
        if (uploadRes.statusCode < 200 || uploadRes.statusCode >= 300) {
          throw HttpException(
              'Drive upload failed (HTTP ${uploadRes.statusCode}): $uploadBody');
        }
        final fileId =
            (jsonDecode(uploadBody) as Map<String, dynamic>)['id'] as String;

        // 3. Share it: anyone with the link is a VIEWER. Done before the
        // link leaves this method, so the recipient never hits a prompt.
        final permRes = await client.post(
          Uri.parse('$_apiBase/files/$fileId/permissions'),
          headers: {'Content-Type': 'application/json; charset=UTF-8'},
          body: jsonEncode({'role': 'reader', 'type': 'anyone'}),
        );
        if (permRes.statusCode < 200 || permRes.statusCode >= 300) {
          throw HttpException(
              'Drive share failed (HTTP ${permRes.statusCode}): ${permRes.body}');
        }

        // 4. Fetch the canonical view link.
        final metaRes = await client.get(
          Uri.parse('$_apiBase/files/$fileId?fields=webViewLink'),
        );
        if (metaRes.statusCode != 200) {
          throw HttpException(
              'Drive link fetch failed (HTTP ${metaRes.statusCode}): ${metaRes.body}');
        }
        final url = (jsonDecode(metaRes.body) as Map<String, dynamic>)['webViewLink']
            as String;

        // 5. Best-effort housekeeping so the 15 GB never fills.
        await _cleanupOldUploads(client);

        return url;
      } on HttpException {
        if (attempt >= retryDelaysSeconds.length) rethrow;
        await Future.delayed(Duration(seconds: retryDelaysSeconds[attempt]));
      } catch (_) {
        // Socket/timeout — transient, retry with backoff.
        if (attempt >= retryDelaysSeconds.length) rethrow;
        await Future.delayed(Duration(seconds: retryDelaysSeconds[attempt]));
      } finally {
        client?.close();
      }
    }
  }

  /// Deletes app-uploaded ZIPs older than 30 days. drive.file scope means we
  /// only ever see files this app created, so this can't touch anything else.
  static Future<void> _cleanupOldUploads(gauth.AutoRefreshingAuthClient client) async {
    try {
      final cutoff =
          DateTime.now().toUtc().subtract(const Duration(days: 30)).toIso8601String();
      final q = Uri.encodeQueryComponent(
          "mimeType='application/zip' and modifiedTime < '$cutoff'");
      final listRes = await client.get(
        Uri.parse('$_apiBase/files?q=$q&fields=files(id)&pageSize=100'),
      );
      if (listRes.statusCode != 200) return;
      final files =
          ((jsonDecode(listRes.body) as Map<String, dynamic>)['files'] as List)
              .cast<Map<String, dynamic>>();
      for (final f in files) {
        try {
          await client.delete(Uri.parse('$_apiBase/files/${f['id']}'));
        } catch (_) {/* best-effort */}
      }
    } catch (_) {/* best-effort */}
  }
}
