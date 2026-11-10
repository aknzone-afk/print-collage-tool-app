import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:http/http.dart' as http;

import 'onedrive_auth.dart';

class OneDriveFile {
  final String id;
  final String name;
  final int size;
  final String? mimeType;
  final String? smallThumbUrl;
  final String? mediumThumbUrl;

  /// OneDrive content tag — changes whenever the file's CONTENT changes.
  /// Used as the cache-busting key for the on-device design cache.
  final String? cTag;

  const OneDriveFile({
    required this.id,
    required this.name,
    required this.size,
    this.mimeType,
    this.smallThumbUrl,
    this.mediumThumbUrl,
    this.cTag,
  });

  String get nameWithoutExtension {
    final dot = name.lastIndexOf('.');
    return dot < 0 ? name : name.substring(0, dot);
  }
}

class OneDriveClient {
  static const _graphBase = 'https://graph.microsoft.com/v1.0';

  final OneDriveAuth auth;

  OneDriveClient(this.auth);

  /// GET with retry + exponential backoff. Background renders run with the
  /// screen off, where Android loves to briefly cut the radio — a single
  /// "connection abort" (errno 103) must NOT kill a 40-design order.
  ///
  /// Retries on: any network-layer exception, HTTP 429 (throttled by Graph)
  /// and HTTP 5xx (transient server errors). Re-fetches the auth token on
  /// each attempt so an expiring token doesn't wedge long renders.
  Future<http.Response> _getWithRetry(String url, String label) async {
    const retryDelaysSeconds = [2, 5, 10, 20, 40];
    for (var attempt = 0;; attempt++) {
      try {
        final token = await auth.getAccessToken();
        final res = await http.get(
          Uri.parse(url),
          headers: {'Authorization': 'Bearer $token'},
        ).timeout(const Duration(minutes: 3));
        final retryable = res.statusCode == 429 || res.statusCode >= 500;
        if (!retryable || attempt >= retryDelaysSeconds.length) {
          _ensureOk(res, label);
          return res;
        }
      } on HttpException {
        rethrow; // non-retryable HTTP error surfaced by _ensureOk
      } catch (_) {
        // SocketException / ClientException / TimeoutException / token
        // refresh hiccup — all worth retrying until the budget runs out.
        if (attempt >= retryDelaysSeconds.length) rethrow;
      }
      await Future.delayed(Duration(seconds: retryDelaysSeconds[attempt]));
    }
  }

  Future<List<OneDriveFile>> listFolderByPath(
    String folderPath, {
    void Function(int loadedSoFar)? onProgress,
  }) async {
    final cleanPath = folderPath.replaceAll(RegExp(r'^/+|/+$'), '');
    // Tiny payload: just id, name, and file existence flag. Skip size, thumbnails,
    // mimetypes — anything we don't strictly need for the dropdown. Cuts response
    // size ~70-80% which dramatically speeds up listing 8000+ designs over LTE.
    String? url =
        '$_graphBase/me/drive/root:/$cleanPath:/children?\$top=999&\$select=id,name,file,cTag';

    final result = <OneDriveFile>[];
    while (url != null) {
      final res = await _getWithRetry(url, 'List folder "$folderPath"');
      final body = jsonDecode(res.body) as Map<String, dynamic>;
      final items = (body['value'] as List).cast<Map<String, dynamic>>();
      for (final it in items) {
        if (it['file'] == null) continue;
        result.add(OneDriveFile(
          id: it['id'] as String,
          name: it['name'] as String,
          size: 0,
          cTag: it['cTag'] as String?,
        ));
      }
      onProgress?.call(result.length);
      url = body['@odata.nextLink'] as String?;
    }
    return result;
  }

  Future<Uint8List> downloadFile(String fileId) async {
    final res = await _getWithRetry(
      '$_graphBase/me/drive/items/$fileId/content',
      'Download file $fileId',
    );
    return res.bodyBytes;
  }

  Future<OneDriveFile?> findByDesignId(String folderPath, String designId) async {
    final files = await listFolderByPath(folderPath);
    final lower = designId.toLowerCase();
    for (final f in files) {
      if (f.nameWithoutExtension.toLowerCase() == lower) return f;
    }
    return null;
  }

  Future<Map<String, dynamic>> getMyProfile() async {
    final res = await _getWithRetry('$_graphBase/me', 'Fetch profile');
    return jsonDecode(res.body) as Map<String, dynamic>;
  }

  void _ensureOk(http.Response res, String label) {
    if (res.statusCode < 200 || res.statusCode >= 300) {
      throw HttpException(label, res.statusCode, res.body);
    }
  }
}

class HttpException implements Exception {
  final String label;
  final int statusCode;
  final String body;
  HttpException(this.label, this.statusCode, this.body);
  @override
  String toString() => '$label failed (HTTP $statusCode): $body';
}
