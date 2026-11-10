import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

import 'onedrive_auth.dart';
import 'onedrive_client.dart';

const _graphBase = 'https://graph.microsoft.com/v1.0';
const _cacheFileName = 'designs_cache.json';

class DesignEntry {
  final String designId;
  final String fileId;
  final String? smallThumbUrl;
  final String? mediumThumbUrl;
  const DesignEntry({
    required this.designId,
    required this.fileId,
    this.smallThumbUrl,
    this.mediumThumbUrl,
  });
}

/// Caches OneDrive design listings + thumbnails so the order screen can show
/// fast in-memory autocomplete with photo previews — no network on every keystroke.
class DesignLibrary {
  final OneDriveAuth auth;

  String? _cachedFolder;
  List<DesignEntry>? _cachedEntries;
  Future<List<DesignEntry>>? _inflight;
  int _loadProgress = 0;
  void Function(int loaded)? onLoadProgress;
  final Map<String, Uint8List> _thumbBytes = {};
  final Map<String, Future<Uint8List?>> _thumbInflight = {};

  DesignLibrary(this.auth);

  int get loadProgress => _loadProgress;
  bool get isLoading => _inflight != null;

  bool isLoadedFor(String folder) =>
      _cachedFolder == folder && _cachedEntries != null;

  List<DesignEntry>? cachedEntries(String folder) =>
      _cachedFolder == folder ? _cachedEntries : null;

  /// Synchronous list of just the design IDs (for autocomplete filtering).
  List<String>? cachedIds(String folder) =>
      cachedEntries(folder)?.map((e) => e.designId).toList();

  Future<List<DesignEntry>> getEntries(String folder) async {
    if (_cachedFolder == folder && _cachedEntries != null) return _cachedEntries!;
    if (_inflight != null) return _inflight!;
    _inflight = _fetch(folder);
    try {
      final entries = await _inflight!;
      _cachedFolder = folder;
      _cachedEntries = entries;
      _saveToDisk(); // fire-and-forget — don't block on disk write
      return entries;
    } finally {
      _inflight = null;
    }
  }

  /// Loads the cached design list from disk if it matches [folder].
  /// Used as the first source on app open — list shows instantly while
  /// a network refresh runs in the background.
  Future<bool> tryLoadFromDisk(String folder) async {
    try {
      final f = await _cacheFile();
      if (!await f.exists()) return false;
      final raw = await f.readAsString();
      final data = jsonDecode(raw) as Map<String, dynamic>;
      if (data['folder'] != folder) return false;
      final list = (data['entries'] as List).cast<Map<String, dynamic>>();
      final entries = list
          .map((m) => DesignEntry(
                designId: m['designId'] as String,
                fileId: m['fileId'] as String,
              ))
          .toList();
      _cachedFolder = folder;
      _cachedEntries = entries;
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<File> _cacheFile() async {
    final dir = await getApplicationDocumentsDirectory();
    return File('${dir.path}/$_cacheFileName');
  }

  Future<void> _saveToDisk() async {
    try {
      if (_cachedFolder == null || _cachedEntries == null) return;
      final f = await _cacheFile();
      await f.writeAsString(jsonEncode({
        'folder': _cachedFolder,
        'savedAt': DateTime.now().toIso8601String(),
        'entries': _cachedEntries!
            .map((e) => {'designId': e.designId, 'fileId': e.fileId})
            .toList(),
      }));
    } catch (_) {/* swallow — disk is non-essential */}
  }

  Future<void> _deleteCache() async {
    try {
      final f = await _cacheFile();
      if (await f.exists()) await f.delete();
    } catch (_) {/* swallow */}
  }

  Future<List<String>> getDesignIds(String folder) async =>
      (await getEntries(folder)).map((e) => e.designId).toList();

  Future<List<DesignEntry>> refresh(String folder) async {
    invalidate();
    return getEntries(folder);
  }

  Future<List<DesignEntry>> _fetch(String folder) async {
    final client = OneDriveClient(auth);
    _loadProgress = 0;
    onLoadProgress?.call(0);
    final files = await client.listFolderByPath(
      folder,
      onProgress: (n) {
        _loadProgress = n;
        onLoadProgress?.call(n);
      },
    );
    final entries = files
        .map((f) => DesignEntry(
              designId: f.nameWithoutExtension,
              fileId: f.id,
              smallThumbUrl: f.smallThumbUrl,
              mediumThumbUrl: f.mediumThumbUrl,
            ))
        .toList()
      ..sort((a, b) => a.designId.toLowerCase().compareTo(b.designId.toLowerCase()));
    return entries;
  }

  /// sanitizedId -> full path of the downloaded design file. Built lazily
  /// from one directory scan, then every lookup is O(1) — fast enough to
  /// run per autocomplete row on every keystroke.
  Map<String, String>? _localIndex;
  DateTime _localIndexBuilt = DateTime.fromMillisecondsSinceEpoch(0);

  Future<void> _buildLocalIndex() async {
    final map = <String, String>{};
    try {
      final dir = await getApplicationDocumentsDirectory();
      final cacheDir = Directory('${dir.path}/design_cache');
      if (await cacheDir.exists()) {
        await for (final e in cacheDir.list()) {
          if (e is! File) continue;
          final name = e.uri.pathSegments.last;
          final at = name.indexOf('@');
          if (at > 0 && name.endsWith('.jpg')) {
            map[name.substring(0, at)] = e.path;
          }
        }
      }
    } catch (_) {/* empty index — lookups fall back to network */}
    _localIndex = map;
    _localIndexBuilt = DateTime.now();
  }

  /// Local-first image lookup: the background prefetch (and every render)
  /// stores designs as slot-sized JPEGs in design_cache/ (filenames are
  /// `<sanitizedId>@<ctag>.jpg` — MUST stay in sync with
  /// order_render_task.dart). Returns the downloaded file instantly, or
  /// null for designs not on the phone yet (caller falls back to OneDrive
  /// thumbnails). Works offline.
  Future<File?> getCachedDesignFile(String designId) async {
    final safe = designId.replaceAll(RegExp(r'[^a-zA-Z0-9]'), '_');
    if (_localIndex == null) await _buildLocalIndex();
    var path = _localIndex![safe];
    if (path == null &&
        DateTime.now().difference(_localIndexBuilt) >
            const Duration(seconds: 30)) {
      // The prefetch may have downloaded it since the index was built.
      await _buildLocalIndex();
      path = _localIndex![safe];
    }
    if (path == null) return null;
    final f = File(path);
    if (await f.exists()) return f;
    // Stale entry — the picture was replaced (new cTag = new filename) or
    // LRU-pruned. Rebuild immediately and retry once so a just-changed
    // design shows its NEW photo on the very next lookup.
    _localIndex!.remove(safe);
    await _buildLocalIndex();
    final fresh = _localIndex![safe];
    if (fresh == null) return null;
    final f2 = File(fresh);
    return await f2.exists() ? f2 : null;
  }

  /// Byte variant of [getCachedDesignFile] for callers that need memory
  /// images (order-summary rows).
  Future<Uint8List?> getCachedDesignBytes(String designId) async {
    try {
      final f = await getCachedDesignFile(designId);
      return f == null ? null : await f.readAsBytes();
    } catch (_) {
      return null;
    }
  }

  /// Returns thumbnail bytes for a designId, downloading + caching if needed.
  /// Returns null only if there's no entry for [designId] in the cache.
  /// Falls back from cached URL → direct Graph API fetch for robustness.
  Future<Uint8List?> getThumbnail(String designId, {String size = 'medium'}) async {
    final cacheKey = '$designId@$size';
    if (_thumbBytes.containsKey(cacheKey)) return _thumbBytes[cacheKey];
    if (_thumbInflight.containsKey(cacheKey)) return _thumbInflight[cacheKey];

    // Case/whitespace-insensitive: the typed order id "5257 " must still
    // match the OneDrive file named "5257".
    final wanted = designId.trim().toLowerCase();
    final entry = _cachedEntries?.firstWhere(
      (e) => e.designId.trim().toLowerCase() == wanted,
      orElse: () => const DesignEntry(designId: '', fileId: ''),
    );
    if (entry == null || entry.designId.isEmpty) return null;

    final future = _loadThumbnail(entry, size, cacheKey);
    _thumbInflight[cacheKey] = future;
    try {
      return await future;
    } finally {
      _thumbInflight.remove(cacheKey);
    }
  }

  /// Memoize a thumbnail with a hard cap. Uncapped, a session of browsing
  /// the 1500+ design autocomplete accumulated hundreds of MB of thumbnail
  /// bytes in the UI process — stacking that under the render peaks is what
  /// pushed the process over ColorOS's kill threshold. Insertion order
  /// doubles as an LRU-ish eviction order.
  void _memoThumb(String cacheKey, Uint8List bytes) {
    const maxEntries = 200;
    while (_thumbBytes.length >= maxEntries) {
      _thumbBytes.remove(_thumbBytes.keys.first);
    }
    _thumbBytes[cacheKey] = bytes;
  }

  Future<Uint8List?> _loadThumbnail(DesignEntry entry, String size, String cacheKey) async {
    final urlFromCache = size == 'small' ? entry.smallThumbUrl : entry.mediumThumbUrl;
    if (urlFromCache != null) {
      final bytes = await _downloadFromUrl(urlFromCache);
      if (bytes != null) {
        _memoThumb(cacheKey, bytes);
        return bytes;
      }
    }
    final bytes = await _downloadFromGraph(entry.fileId, size);
    if (bytes != null) {
      _memoThumb(cacheKey, bytes);
      return bytes;
    }
    return null;
  }

  Future<Uint8List?> _downloadFromUrl(String url) async {
    try {
      final res = await http.get(Uri.parse(url));
      if (res.statusCode == 200) return res.bodyBytes;
    } catch (_) {/* swallow */}
    return null;
  }

  Future<Uint8List?> _downloadFromGraph(String fileId, String size) async {
    try {
      final token = await auth.getAccessToken();
      final res = await http.get(
        Uri.parse('$_graphBase/me/drive/items/$fileId/thumbnails/0/$size/content'),
        headers: {'Authorization': 'Bearer $token'},
      );
      if (res.statusCode == 200) return res.bodyBytes;
    } catch (_) {/* swallow */}
    return null;
  }

  void invalidate() {
    _cachedFolder = null;
    _cachedEntries = null;
    _inflight = null;
    _thumbBytes.clear();
    _thumbInflight.clear();
    _deleteCache();
  }
}
