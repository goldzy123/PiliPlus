import 'dart:async';

import 'package:PiliPlus/utils/storage.dart';
import 'package:PiliPlus/utils/extension/get_ext.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:dio/dio.dart';
import 'package:get/get.dart';
import 'package:hive_ce/hive.dart';

/// 配置同步（mod）。
///
/// 只同步**偏好设置**：`setting` / `video` 两个 Hive box 里的键，
/// 排除凭据类与设备相关项。账号、登录态、观看进度、搜索历史、缓存都不碰。
///
/// 服务端是局域网里的一个小 HTTP 服务，见 `mod/server/`。
abstract final class SyncKeys {
  static const enabled = 'mod_sync_enabled';
  static const url = 'mod_sync_url';
  static const token = 'mod_sync_token';
  static const profile = 'mod_sync_profile';
  static const auto = 'mod_sync_auto';
  static const rev = 'mod_sync_rev';
  static const device = 'mod_sync_device';
  static const lastSyncAt = 'mod_sync_last_at';
}

abstract final class SyncConfig {
  static Box get _box => GStorage.setting;

  static bool get enabled => _box.get(SyncKeys.enabled, defaultValue: false);
  static set enabled(bool v) => _box.put(SyncKeys.enabled, v);

  static String get url => _box.get(SyncKeys.url, defaultValue: '');
  static set url(String v) => _box.put(SyncKeys.url, v);

  static String get token => _box.get(SyncKeys.token, defaultValue: '');
  static set token(String v) => _box.put(SyncKeys.token, v);

  static String get profile => _box.get(SyncKeys.profile, defaultValue: '');
  static set profile(String v) => _box.put(SyncKeys.profile, v);

  static bool get auto => _box.get(SyncKeys.auto, defaultValue: false);
  static set auto(bool v) => _box.put(SyncKeys.auto, v);

  static int get rev => _box.get(SyncKeys.rev, defaultValue: 0);
  static set rev(int v) => _box.put(SyncKeys.rev, v);

  static int get lastSyncAt => _box.get(SyncKeys.lastSyncAt, defaultValue: 0);
  static set lastSyncAt(int v) => _box.put(SyncKeys.lastSyncAt, v);

  static String get device => _box.get(SyncKeys.device, defaultValue: '');
  static set device(String v) => _box.put(SyncKeys.device, v);
}

/// 同步白名单/黑名单。键名里带这些片段的**不同步**。
const _excludedFragments = <String>[
  'webdav', // 网盘地址与口令
  'password',
  'passwd',
  'token',
  'secret',
  'apikey',
  'api_key',
  'cookie',
  'account',
  'login',
  'path',
  'dir',
  'deviceid', // 局域网接力的本机 ID，每台设备不同
];

/// 明确排除的整键（含设备本地状态）
const _excludedKeys = <String>{
  'mod_local_videos', // 本地视频列表存的是本机文件路径
};

bool _syncable(String key) {
  final lower = key.toLowerCase();
  if (_excludedKeys.contains(key)) return false;
  for (final f in _excludedFragments) {
    if (lower.contains(f)) return false;
  }
  // mod 自己的同步配置不同步（否则会把服务器地址/口令同步来同步去）
  if (key.startsWith('mod_sync_')) return false;
  return true;
}

class SyncProfileInfo {
  const SyncProfileInfo({
    required this.name,
    required this.rev,
    required this.updatedAt,
    required this.device,
  });

  final String name;
  final int rev;
  final int updatedAt;
  final String device;
}

class SettingsSyncService extends GetxController {
  static SettingsSyncService get to => Get.putOrFind(SettingsSyncService.new);

  final status = '未启用'.obs;
  final busy = false.obs;
  final profiles = <SyncProfileInfo>[].obs;

  Dio? _dio;
  Timer? _timer;
  Timer? _debounce;
  StreamSubscription? _settingSub;
  StreamSubscription? _videoSub;
  bool _applying = false;

  @override
  void onInit() {
    super.onInit();
    if (SyncConfig.enabled) {
      unawaited(start());
    }
  }

  @override
  void onClose() {
    stop();
    super.onClose();
  }

  Dio get _client {
    final base = SyncConfig.url.trim();
    if (_dio == null || _dio!.options.baseUrl != base) {
      _dio = Dio(
        BaseOptions(
          baseUrl: base,
          connectTimeout: const Duration(seconds: 5),
          receiveTimeout: const Duration(seconds: 15),
          sendTimeout: const Duration(seconds: 15),
          headers: {
            if (SyncConfig.token.isNotEmpty) 'x-token': SyncConfig.token,
          },
        ),
      );
    }
    return _dio!;
  }

  /// 拿一个稳定的设备名，用来标记"最后是谁改的"。
  Future<String> deviceName() async {
    final saved = SyncConfig.device;
    if (saved.isNotEmpty) return saved;
    String name = 'device';
    try {
      final info = DeviceInfoPlugin();
      final android = await info.androidInfo;
      name = '${android.brand}-${android.model}';
    } catch (_) {}
    SyncConfig.device = name;
    return name;
  }

  // ── 采集 / 应用 ────────────────────────────────────────────────

  /// 把两个 box 里可同步的键打包成 JSON。
  Map<String, dynamic> collect() {
    Map<String, dynamic> dump(Box box) {
      final out = <String, dynamic>{};
      for (final key in box.keys) {
        final k = key.toString();
        if (!_syncable(k)) continue;
        final v = box.get(key);
        if (v == null) continue;
        // Hive 存的基本都是 JSON 友好的类型；遇到不认识的直接跳过
        if (v is Map || v is List || v is String || v is num || v is bool) {
          out[k] = v is Map ? Map<String, dynamic>.from(v) : v;
        }
      }
      return out;
    }

    return {
      'version': 1,
      'exportedAt': DateTime.now().millisecondsSinceEpoch,
      'boxes': {
        'setting': dump(GStorage.setting),
        'video': dump(GStorage.video),
      },
    };
  }

  /// 把远端数据写回本地（只做覆盖写入，不删除本地独有的键）。
  Future<int> apply(Map<String, dynamic> data) async {
    final boxes = data['boxes'];
    if (boxes is! Map) return 0;
    var count = 0;
    _applying = true;
    try {
      for (final entry in {'setting': GStorage.setting, 'video': GStorage.video}.entries) {
        final incoming = boxes[entry.key];
        if (incoming is! Map) continue;
        final patch = <String, dynamic>{};
        for (final e in incoming.entries) {
          final k = e.key.toString();
          if (!_syncable(k)) continue;
          patch[k] = e.value;
        }
        if (patch.isEmpty) continue;
        await entry.value.putAll(patch);
        count += patch.length;
      }
    } finally {
      _applying = false;
    }
    // 让已经构建好的界面重新读一遍 Pref
    Get.forceAppUpdate();
    return count;
  }

  // ── 远端操作 ───────────────────────────────────────────────────

  Future<void> refreshProfiles() async {
    if (SyncConfig.url.trim().isEmpty) {
      profiles.clear();
      return;
    }
    final res = await _client.get('/api/profiles');
    final list = (res.data?['profiles'] as List?) ?? const [];
    profiles.value = [
      for (final e in list)
        SyncProfileInfo(
          name: e['name']?.toString() ?? '',
          rev: (e['rev'] as num?)?.toInt() ?? 0,
          updatedAt: (e['updatedAt'] as num?)?.toInt() ?? 0,
          device: e['device']?.toString() ?? '',
        ),
    ];
  }

  /// 把本地配置推到远端配置名。
  Future<void> push({String? name, int? baseRev}) async {
    final target = (name ?? SyncConfig.profile).trim();
    if (target.isEmpty) throw '请先填配置名';
    final res = await _client.put(
      '/api/profiles/${Uri.encodeComponent(target)}',
      data: {
        'data': collect(),
        'baseRev': baseRev ?? SyncConfig.rev,
        'device': await deviceName(),
      },
    );
    SyncConfig.profile = target;
    SyncConfig.rev = (res.data?['rev'] as num?)?.toInt() ?? SyncConfig.rev;
    SyncConfig.lastSyncAt = DateTime.now().millisecondsSinceEpoch;
    status.value = '已上传（rev ${SyncConfig.rev}）';
  }

  /// 从远端配置名拉取并应用。
  Future<int> pull({String? name, bool force = false}) async {
    final target = (name ?? SyncConfig.profile).trim();
    if (target.isEmpty) throw '请先填配置名';
    final res = await _client.get('/api/profiles/${Uri.encodeComponent(target)}');
    final rev = (res.data?['rev'] as num?)?.toInt() ?? 0;
    if (!force && rev <= SyncConfig.rev) {
      status.value = '已是最新（rev $rev）';
      return 0;
    }
    final data = res.data?['data'];
    if (data is! Map) throw '远端数据格式不对';
    final n = await apply(Map<String, dynamic>.from(data));
    SyncConfig.profile = target;
    SyncConfig.rev = rev;
    SyncConfig.lastSyncAt = DateTime.now().millisecondsSinceEpoch;
    status.value = '已拉取 rev $rev，应用 $n 项';
    return n;
  }

  // ── 自动同步 ───────────────────────────────────────────────────

  Future<void> start() async {
    stop();
    SyncConfig.enabled = true;
    if (SyncConfig.url.trim().isEmpty || SyncConfig.profile.trim().isEmpty) {
      status.value = '请先填服务器地址与配置名';
      return;
    }
    status.value = '自动同步已开启';
    if (SyncConfig.auto) {
      // 本地改动 → 防抖上传
      _settingSub = GStorage.setting.watch().listen(_onLocalChange);
      _videoSub = GStorage.video.watch().listen(_onLocalChange);
      // 远端改动 → 定时拉取
      _timer = Timer.periodic(const Duration(seconds: 20), (_) async {
        if (busy.value || _applying) return;
        try {
          busy.value = true;
          await pull();
        } catch (e) {
          status.value = '拉取失败：$e';
        } finally {
          busy.value = false;
        }
      });
    }
  }

  void stop() {
    SyncConfig.enabled = false;
    _timer?.cancel();
    _timer = null;
    _debounce?.cancel();
    _debounce = null;
    _settingSub?.cancel();
    _settingSub = null;
    _videoSub?.cancel();
    _videoSub = null;
  }

  void _onLocalChange(BoxEvent event) {
    if (_applying || !SyncConfig.auto) return;
    _debounce?.cancel();
    _debounce = Timer(const Duration(seconds: 3), () async {
      if (busy.value || _applying) return;
      try {
        busy.value = true;
        await push();
      } catch (e) {
        status.value = '上传失败：$e';
      } finally {
        busy.value = false;
      }
    });
  }
}
