import 'dart:io';

import 'package:PiliPlus/models/common/video/source_type.dart';
import 'package:PiliPlus/utils/page_utils.dart';
import 'package:PiliPlus/utils/path_utils.dart';
import 'package:PiliPlus/utils/storage.dart';
import 'package:file_picker/file_picker.dart';
import 'package:get/get.dart';
import 'package:hive_ce/hive.dart';
import 'package:path/path.dart' as path;
import 'package:PiliPlus/utils/permission_handler.dart';

/// 认作视频的扩展名。
const _videoExts = <String>{
  'mp4', 'mkv', 'webm', 'avi', 'mov', 'flv', 'ts', 'm2ts', 'm4v',
  'wmv', 'mpg', 'mpeg', 'rmvb', 'rm', '3gp', 'ogv', 'vob', 'mts',
};

/// 一条本地视频记录。
class LocalVideoItem {
  const LocalVideoItem({
    required this.path,
    required this.name,
    this.addedAt = 0,
    this.folder,
    this.size = 0,
  });

  final String path;
  final String name;
  final int addedAt;

  /// 来自哪个「常用目录」的绝对路径；手动添加的为 null
  final String? folder;

  /// 文件大小（字节），扫描时记录
  final int size;

  Map<String, dynamic> toJson() => {
    'path': path,
    'name': name,
    'addedAt': addedAt,
    if (folder != null) 'folder': folder,
    'size': size,
  };

  factory LocalVideoItem.fromJson(Map<String, dynamic> json) => LocalVideoItem(
    path: json['path'] as String? ?? '',
    name: json['name'] as String? ?? '',
    addedAt: (json['addedAt'] as num?)?.toInt() ?? 0,
    folder: json['folder'] as String?,
    size: (json['size'] as num?)?.toInt() ?? 0,
  );
}

/// 一个「常用目录」。
class LocalFolder {
  const LocalFolder({
    required this.path,
    required this.name,
    this.addedAt = 0,
  });

  final String path;
  final String name;
  final int addedAt;

  Map<String, dynamic> toJson() => {
    'path': path,
    'name': name,
    'addedAt': addedAt,
  };

  factory LocalFolder.fromJson(Map<String, dynamic> json) => LocalFolder(
    path: json['path'] as String? ?? '',
    name: json['name'] as String? ?? '',
    addedAt: (json['addedAt'] as num?)?.toInt() ?? 0,
  );
}

enum LocalVideoSort {
  addedDesc('最近添加'),
  nameAsc('名称'),
  sizeDesc('文件大小'),
  progressDesc('观看进度');

  final String label;
  const LocalVideoSort(this.label);
}

/// 本地视频的持久化。
///
/// 直接往 setting box 里写自有键，避免改官方 `storage_key.dart`
/// （mod 的 hook 越少越容易跟上游合并）。
abstract final class LocalVideoStore {
  static const boxKey = 'mod_local_videos';
  static const folderKey = 'mod_local_folders';

  static Box get _box => GStorage.setting;

  /// 丢记录前先确认文件还在，避免列表里全是死链
  static bool _alive(String p) => p.isNotEmpty && File(p).existsSync();

  static List<LocalVideoItem> load() {
    final raw = _box.get(boxKey);
    // 必须返回可变列表：const [] 赋给 RxList 后 addAll 会抛
    // UnmodifiableListMixin（踩过一次）
    if (raw is! List) return <LocalVideoItem>[];
    return raw
        .whereType<Map>()
        .map((e) => LocalVideoItem.fromJson(Map<String, dynamic>.from(e)))
        .where((e) => _alive(e.path))
        .toList();
  }

  static Future<void> save(List<LocalVideoItem> list) =>
      _box.put(boxKey, list.map((e) => e.toJson()).toList());

  static List<LocalFolder> loadFolders() {
    final raw = _box.get(folderKey);
    if (raw is! List) return <LocalFolder>[];
    return raw
        .whereType<Map>()
        .map((e) => LocalFolder.fromJson(Map<String, dynamic>.from(e)))
        .where((e) => e.path.isNotEmpty)
        .toList();
  }

  static Future<void> saveFolders(List<LocalFolder> list) =>
      _box.put(folderKey, list.map((e) => e.toJson()).toList());

  /// 稳定哈希（FNV-1a）：拿文件路径当进度记忆的 cid。
  /// 不能用 String.hashCode —— 它不保证跨版本稳定，会让进度丢失。
  static int stableHash(String s) {
    var h = 0x811c9dc5;
    for (final c in s.codeUnits) {
      h ^= c;
      h = (h * 0x01000193) & 0x7fffffff;
    }
    return h;
  }

  /// 该视频上次看到哪儿（毫秒），没有记录返回 0。
  /// 官方视频页就是拿 cid 去 `watchProgress` 里存取进度的，
  /// 本地视频复用同一套（cid = 文件路径哈希）。
  static int progressMsOf(String filePath) {
    final v = GStorage.watchProgress.get(stableHash(filePath).toString());
    return v ?? 0;
  }

  static Future<void> clearProgressOf(String filePath) =>
      GStorage.watchProgress.delete(stableHash(filePath).toString());

  static bool isVideoFile(String p) {
    final ext = path.extension(p).replaceFirst('.', '').toLowerCase();
    return _videoExts.contains(ext);
  }

  /// 把插件给的临时文件挪进 app 私有目录。
  ///
  /// Android 上 file_picker 会把选中的文件复制到 `cache/file_picker/xxx`，
  /// 而 cache 随时可能被系统清掉（清了记录就失效）。同一文件系统内 rename
  /// 不搬数据，所以这里几乎是零成本。
  ///
  /// 注意：**扫描目录得到的文件不需要搬** —— 它本来就在用户自己的目录里，
  /// 搬走反而会让用户找不到。
  static Future<String> persist(String srcPath, String name) async {
    try {
      if (!File(srcPath).existsSync()) return srcPath;
      final dir = Directory(path.join(appSupportDirPath, 'localVideos'));
      if (!dir.existsSync()) await dir.create(recursive: true);
      final target = path.join(
        dir.path,
        '${DateTime.now().millisecondsSinceEpoch}_$name',
      );
      await File(srcPath).rename(target);
      return target;
    } catch (_) {
      // 跨文件系统等异常：保持原路径，至少本次能用
      return srcPath;
    }
  }

  /// 把毫秒格式化成 `12:34` / `1:02:03`
  static String fmt(int ms) {
    if (ms <= 0) return '';
    final d = Duration(milliseconds: ms);
    final h = d.inHours;
    final m = d.inMinutes.remainder(60).toString().padLeft(h > 0 ? 2 : 1, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return h > 0 ? '$h:$m:$s' : '$m:$s';
  }

  /// 人类可读的大小
  static String fmtSize(int bytes) {
    if (bytes <= 0) return '';
    const units = ['B', 'KB', 'MB', 'GB', 'TB'];
    var v = bytes.toDouble();
    var i = 0;
    while (v >= 1024 && i < units.length - 1) {
      v /= 1024;
      i++;
    }
    return '${v.toStringAsFixed(v >= 100 || i == 0 ? 0 : 1)}${units[i]}';
  }
}

/// 选片结果，用来给用户明确反馈（而不是静默什么都不发生）。
class LocalVideoPickResult {
  const LocalVideoPickResult({
    this.added = 0,
    this.duplicated = 0,
    this.failed = 0,
  });

  final int added;

  /// 已经在列表里的
  final int duplicated;

  /// 拿不到本地路径的（理论上 Android 上不会发生：插件一定会复制到 cache）
  final int failed;

  bool get isEmpty => added == 0 && duplicated == 0 && failed == 0;

  String get message {
    if (added > 0) return '已添加 $added 个视频';
    if (duplicated > 0) return '这些视频已经在列表里了';
    if (failed > 0) return '有 $failed 个文件读不到路径，添加失败';
    return '';
  }
}

class LocalVideoController extends GetxController {
  final list = <LocalVideoItem>[].obs;
  final folders = <LocalFolder>[].obs;
  final keyword = ''.obs;
  final sort = LocalVideoSort.addedDesc.obs;
  final scanning = false.obs;

  @override
  void onInit() {
    super.onInit();
    list.assignAll(LocalVideoStore.load());
    folders.assignAll(LocalVideoStore.loadFolders());
  }

  /// 搜索 + 排序之后的列表
  List<LocalVideoItem> get visible {
    final kw = keyword.value.trim().toLowerCase();
    final out = kw.isEmpty
        ? list.toList()
        : list.where((e) => e.name.toLowerCase().contains(kw)).toList();
    switch (sort.value) {
      case LocalVideoSort.addedDesc:
        out.sort((a, b) => b.addedAt.compareTo(a.addedAt));
      case LocalVideoSort.nameAsc:
        out.sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
      case LocalVideoSort.sizeDesc:
        out.sort((a, b) => b.size.compareTo(a.size));
      case LocalVideoSort.progressDesc:
        out.sort(
          (a, b) => LocalVideoStore.progressMsOf(
            b.path,
          ).compareTo(LocalVideoStore.progressMsOf(a.path)),
        );
    }
    return out;
  }

  /// 按目录分组（常用目录在前，手动添加的归到最后一组）
  Map<String, List<LocalVideoItem>> get grouped {
    final out = <String, List<LocalVideoItem>>{};
    for (final f in folders) {
      final items = visible.where((e) => e.folder == f.path).toList();
      if (items.isNotEmpty) out[f.name] = items;
    }
    final manual = visible.where((e) => e.folder == null).toList();
    if (manual.isNotEmpty) out['手动添加'] = manual;
    return out;
  }

  int progressOf(LocalVideoItem item) =>
      LocalVideoStore.progressMsOf(item.path);

  // ── 权限 ──────────────────────────────────────────────────────

  /// 申请「所有文件访问」。
  ///
  /// Android 11+ 分区存储下，`READ_MEDIA_VIDEO` 只能按 MediaStore 拿媒体，
  /// **列目录内容**要 MANAGE_EXTERNAL_STORAGE。只在真的要扫描时才申请，
  /// 手动选片那条路完全不需要它。
  Future<bool> ensureScanPermission() async {
    if (!Platform.isAndroid) return true;
    if (await Permission.manageExternalStorage.isGranted) return true;
    final res = await Permission.manageExternalStorage.request();
    if (res.isGranted) return true;
    // 用户拒了（或被跳转到系统设置页后没开）——再查一次真实状态
    return Permission.manageExternalStorage.isGranted;
  }

  // ── 常用目录 ──────────────────────────────────────────────────

  /// 选一个目录加进「常用目录」，并立即扫描一次
  Future<int?> pickFolder() async {
    if (!await ensureScanPermission()) return null;
    final dir = await FilePicker.getDirectoryPath(dialogTitle: '选择常用目录');
    if (dir == null || dir.isEmpty) return null;
    return addFolder(dir);
  }

  Future<int?> addFolder(String dir) async {
    if (folders.any((e) => e.path == dir)) {
      return scanFolder(folders.firstWhere((e) => e.path == dir));
    }
    final f = LocalFolder(
      path: dir,
      name: path.basename(dir).isEmpty ? dir : path.basename(dir),
      addedAt: DateTime.now().millisecondsSinceEpoch,
    );
    folders.add(f);
    await LocalVideoStore.saveFolders(folders);
    return scanFolder(f);
  }

  Future<void> removeFolder(LocalFolder f, {bool removeVideos = true}) async {
    folders.removeWhere((e) => e.path == f.path);
    await LocalVideoStore.saveFolders(folders);
    if (removeVideos) {
      list.removeWhere((e) => e.folder == f.path);
      await LocalVideoStore.save(list);
    }
  }

  /// 递归扫描一个目录，把里面的视频加进列表。返回新增数量。
  Future<int> scanFolder(LocalFolder f) async {
    if (!await ensureScanPermission()) return 0;
    scanning.value = true;
    try {
      final dir = Directory(f.path);
      if (!dir.existsSync()) return 0;
      final exist = list.map((e) => e.path).toSet();
      final added = <LocalVideoItem>[];
      final now = DateTime.now().millisecondsSinceEpoch;
      await for (final ent in dir.list(recursive: true, followLinks: false)) {
        if (ent is! File) continue;
        final p = ent.path;
        if (!LocalVideoStore.isVideoFile(p)) continue;
        if (exist.contains(p)) continue;
        int size = 0;
        try {
          size = await ent.length();
        } catch (_) {}
        added.add(
          LocalVideoItem(
            path: p,
            name: path.basename(p),
            addedAt: now,
            folder: f.path,
            size: size,
          ),
        );
      }
      if (added.isNotEmpty) {
        list.addAll(added);
        await LocalVideoStore.save(list);
      }
      return added.length;
    } catch (_) {
      return 0;
    } finally {
      scanning.value = false;
    }
  }

  Future<int> scanAllFolders() async {
    var n = 0;
    for (final f in folders) {
      n += await scanFolder(f);
    }
    return n;
  }

  // ── 视频 ──────────────────────────────────────────────────────

  /// 用系统文件选择器挑视频（可多选）。
  Future<LocalVideoPickResult> pick() async {
    final res = await FilePicker.pickFiles(
      dialogTitle: '选择视频',
      type: FileType.video,
    );
    if (res.isEmpty) return const LocalVideoPickResult();
    final exist = list.map((e) => e.path).toSet();
    final now = DateTime.now().millisecondsSinceEpoch;
    final added = <LocalVideoItem>[];
    var duplicated = 0;
    var failed = 0;
    for (final f in res) {
      final p = f.path;
      if (p == null || p.isEmpty) {
        failed++;
        continue;
      }
      final saved = await LocalVideoStore.persist(p, f.name);
      if (exist.contains(p) || exist.contains(saved)) {
        duplicated++;
        continue;
      }
      var size = 0;
      try {
        size = await File(saved).length();
      } catch (_) {}
      added.add(
        LocalVideoItem(
          path: saved,
          name: f.name,
          addedAt: now,
          size: size,
        ),
      );
    }
    if (added.isNotEmpty) {
      list.addAll(added);
      await LocalVideoStore.save(list);
    }
    return LocalVideoPickResult(
      added: added.length,
      duplicated: duplicated,
      failed: failed,
    );
  }

  Future<void> remove(LocalVideoItem item) async {
    list.remove(item);
    await LocalVideoStore.save(list);
  }

  Future<void> clear() async {
    list.clear();
    await LocalVideoStore.save(list);
  }

  /// 复用官方视频页（`/videoV`）播放本地文件，走 `SourceType.file` 分支。
  /// 进度由官方那套按 cid 存取，所以再次进来会自动续播。
  Future<void> play(LocalVideoItem item) async {
    final cid = LocalVideoStore.stableHash(item.path);
    await PageUtils.toVideoPage(
      aid: cid,
      cid: cid,
      title: item.name,
      isVertical: false,
      extraArguments: {
        'sourceType': SourceType.file,
        'localVideoPath': item.path,
        'localVideoTitle': item.name,
      },
    );
  }
}
