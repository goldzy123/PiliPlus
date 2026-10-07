import 'dart:io';

import 'package:PiliPlus/models/common/video/source_type.dart';
import 'package:PiliPlus/utils/page_utils.dart';
import 'package:PiliPlus/utils/storage.dart';
import 'package:file_picker/file_picker.dart';
import 'package:get/get.dart';
import 'package:hive_ce/hive.dart';

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
    if (raw is! List) return const [];
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
    final added = <LocalVideoItem>[
      for (final f in res)
        if (f.path case final p? when !exist.contains(p))
          LocalVideoItem(path: p, name: f.name, addedAt: now),
    ];
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
