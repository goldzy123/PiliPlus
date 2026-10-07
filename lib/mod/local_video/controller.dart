import 'dart:io';

import 'package:PiliPlus/models/common/video/source_type.dart';
import 'package:PiliPlus/utils/page_utils.dart';
import 'package:PiliPlus/utils/path_utils.dart';
import 'package:PiliPlus/utils/storage.dart';
import 'package:file_picker/file_picker.dart';
import 'package:get/get.dart';
import 'package:hive_ce/hive.dart';
import 'package:path/path.dart' as path;

/// 一条本地视频记录。
class LocalVideoItem {
  const LocalVideoItem({
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

  factory LocalVideoItem.fromJson(Map<String, dynamic> json) => LocalVideoItem(
    path: json['path'] as String? ?? '',
    name: json['name'] as String? ?? '',
    addedAt: (json['addedAt'] as num?)?.toInt() ?? 0,
  );
}

/// 本地视频列表的持久化。
///
/// 直接往 setting box 里写一个自有的键，避免改官方的 `storage_key.dart`
/// （mod 的 hook 越少越容易跟上游合并）。
abstract final class LocalVideoStore {
  static const boxKey = 'mod_local_videos';

  static Box get _box => GStorage.setting;

  static List<LocalVideoItem> load() {
    final raw = _box.get(boxKey);
    // 注意：必须返回可变列表，const [] 赋给 RxList 后 addAll 会抛
    // UnmodifiableListMixin（踩过一次）
    if (raw is! List) return <LocalVideoItem>[];
    return raw
        .whereType<Map>()
        .map((e) => LocalVideoItem.fromJson(Map<String, dynamic>.from(e)))
        // 文件被删掉的记录直接丢弃
        .where((e) => e.path.isNotEmpty && File(e.path).existsSync())
        .toList();
  }

  static Future<void> save(List<LocalVideoItem> list) =>
      _box.put(boxKey, list.map((e) => e.toJson()).toList());

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

  /// 把插件给的临时文件挪进 app 私有目录。
  ///
  /// Android 上 file_picker 会把选中的文件复制到 `cache/file_picker/xxx`，
  /// 而 cache 随时可能被系统清掉（清了记录就失效）。同一文件系统内 rename
  /// 不搬数据，所以这里几乎是零成本。
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
}

class LocalVideoController extends GetxController {
  final list = <LocalVideoItem>[].obs;

  @override
  void onInit() {
    super.onInit();
    list.value = LocalVideoStore.load();
  }

  /// 用系统文件选择器挑视频（可多选）。
  Future<int> pick() async {
    final res = await FilePicker.pickFiles(
      dialogTitle: '选择视频',
      type: FileType.video,
    );
    if (res.isEmpty) return 0;
    final exist = list.map((e) => e.path).toSet();
    final now = DateTime.now().millisecondsSinceEpoch;
    final added = <LocalVideoItem>[];
    for (final f in res) {
      final p = f.path;
      if (p == null || p.isEmpty || exist.contains(p)) continue;
      added.add(
        LocalVideoItem(
          path: await LocalVideoStore.persist(p, f.name),
          name: f.name,
          addedAt: now,
        ),
      );
    }
    if (added.isEmpty) return 0;
    list.addAll(added);
    await LocalVideoStore.save(list);
    return added.length;
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
