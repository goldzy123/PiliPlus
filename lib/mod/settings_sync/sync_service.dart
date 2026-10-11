import 'dart:async';
import 'dart:convert';

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

  /// 值的类型标签。
  ///
  /// 为什么需要它：JSON 分不出 int/double（服务端是 JS 时更彻底，`1.0` 过一遍
  /// JSON.parse→stringify 就成 `1`），而 Dart 分得很清楚。`double get defaultTextScale`
  /// 读到 int 就抛 `type 'int' is not a subtype of type 'double'`，MaterialApp 构建失败
  /// → 整屏变灰（实测把 S20 的 dev 版搞成这样）。所以采集时把类型记下来，
  /// 应用时按它还原，跨语言往返也不会走样。
  static String _typeTag(dynamic v) {
    if (v is int) return 'int';
    if (v is double) return 'double';
    if (v is bool) return 'bool';
    if (v is String) return 'String';
    if (v is List) {
      return 'List<${v.isEmpty ? '' : _typeTag(v.first)}>';
    }
    if (v is Map) {
      return 'Map<String,${v.isEmpty ? '' : _typeTag(v.values.first)}>';
    }
    return '';
  }

  /// 按类型标签把 JSON 里的值还原成原来的 Dart 类型。
  static dynamic _coerceByTag(String tag, dynamic v) {
    if (v == null) return null;
    switch (tag) {
      case 'int':
        return v is num ? v.toInt() : v;
      case 'double':
        return v is num ? v.toDouble() : v;
      case 'bool':
        return v;
      case 'String':
        return v is String ? v : v.toString();
    }
    if (v is List && tag.startsWith('List<')) {
      final inner = tag.substring(5, tag.length - 1);
      if (inner.isEmpty) return v;
      return [for (final e in v) _coerceByTag(inner, e)];
    }
    if (v is Map && tag.startsWith('Map<String,')) {
      final inner = tag.substring(11, tag.length - 1);
      if (inner.isEmpty) return Map<String, dynamic>.from(v);
      return {
        for (final e in v.entries) e.key.toString(): _coerceByTag(inner, e.value),
      };
    }
    return v;
  }

  /// 老数据没有类型标签时，按「double 优先」纠正 int/double 冲突。
  ///
  /// 依据：类型被破坏的方向只有一个 —— double 被降级成 int（JS 没有 int/double 之分）。
  /// 反过来（本该是 int 却被写成 double）只会来自应用端自己，而那样本地早就报错了。
  /// 所以见到一边是 double 就写 double，既安全又能把已经坏掉的值修回来。
  static dynamic _coerceNumber(dynamic local, dynamic v) {
    if (v is double || local is double) {
      if (v is num) return v.toDouble();
    }
    if (v is int && local is int) return v;
    return v;
  }

  /// 把两个 box 里可同步的键打包成 JSON（带类型清单）。
  Map<String, dynamic> collect() {
    Map<String, dynamic> dump(Box box, Map<String, String> types) {
      final out = <String, dynamic>{};
      for (final key in box.keys) {
        final k = key.toString();
        if (!_syncable(k)) continue;
        final v = box.get(key);
        if (v == null) continue;
        // Hive 存的基本都是 JSON 友好的类型；遇到不认识的直接跳过
        if (v is Map || v is List || v is String || v is num || v is bool) {
          out[k] = v is Map ? Map<String, dynamic>.from(v) : v;
          final tag = _typeTag(v);
          if (tag.isNotEmpty) types[k] = tag;
        }
      }
      return out;
    }

    final settingTypes = <String, String>{};
    final videoTypes = <String, String>{};
    return {
      'version': 2,
      'exportedAt': DateTime.now().millisecondsSinceEpoch,
      'boxes': {
        'setting': dump(GStorage.setting, settingTypes),
        'video': dump(GStorage.video, videoTypes),
      },
      'types': {
        'setting': settingTypes,
        'video': videoTypes,
      },
    };
  }

  /// 把远端数据写回本地（只做覆盖写入，不删除本地独有的键）。
  ///
  /// 返回实际写入的项数；`skipped` 是「远端没带类型信息、本地又没有该键，
  /// 拿不准该写成什么类型」而跳过的项数。
  Future<int> apply(Map<String, dynamic> data, {void Function(int skipped)? onSkipped}) async {
    final boxes = data['boxes'];
    if (boxes is! Map) return 0;
    final types = data['types'] is Map
        ? Map<String, dynamic>.from(data['types'] as Map)
        : const <String, dynamic>{};
    var count = 0;
    var skipped = 0;
    _applying = true;
    try {
      for (final entry in {'setting': GStorage.setting, 'video': GStorage.video}.entries) {
        final incoming = boxes[entry.key];
        if (incoming is! Map) continue;
        final typeMap = types[entry.key] is Map
            ? Map<String, dynamic>.from(types[entry.key] as Map)
            : const <String, dynamic>{};
        final patch = <String, dynamic>{};
        for (final e in incoming.entries) {
          final k = e.key.toString();
          if (!_syncable(k)) continue;
          final local = entry.value.get(k);
          var v = e.value;
          final tag = typeMap[k]?.toString();
          if (tag != null && tag.isNotEmpty) {
            // 1) 远端自带类型 → 按类型还原（最准）
            v = _coerceByTag(tag, v);
          } else if (local != null) {
            // 2) 老格式没有类型信息，本地已有该键 → 按本地类型纠正
            v = _coerceNumber(local, v);
          } else {
            // 3) 老格式 + 本地没有该键 → 类型无从判断。
            //    宁可不写：写错类型会让 app 直接抛异常（首屏变灰），
            //    不写只是这个设置暂时保持默认值。等任一设备重新上传一次
            //    （带上类型清单）就能正常同步。
            skipped++;
            continue;
          }
          patch[k] = v;
        }
        if (patch.isEmpty) continue;
        await entry.value.putAll(patch);
        count += patch.length;
      }
    } finally {
      _applying = false;
    }
    onSkipped?.call(skipped);
    // 注意：这里**不能**调 Get.forceAppUpdate()。
    // 它的实现是 engine.performReassemble()，也就是热重载用的"整个 app 从零重建"
    // （官方注释原话：调用期间触摸事件不生效）。同步在启动阶段一跑就把首屏搞成卡死。
    // 设置项都是现读现用的，不需要重建。
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
        // 发字符串而不是对象：服务端是 JS，`data` 过一遍 JSON.parse/stringify
        // 就会把 1.0 变成 1，double 全部降级成 int（踩过，见 collect() 注释）。
        // 当字符串发，服务端原样存、原样回，一个字节都不动。
        'dataRaw': jsonEncode(collect()),
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
    Map<String, dynamic>? data;
    final raw = res.data?['dataRaw'];
    if (raw is String && raw.isNotEmpty) {
      final decoded = jsonDecode(raw);
      if (decoded is Map) data = Map<String, dynamic>.from(decoded);
    } else if (res.data?['data'] is Map) {
      // 老服务端只回 data 对象
      data = Map<String, dynamic>.from(res.data!['data'] as Map);
    }
    if (data == null) throw '远端数据格式不对';
    var skipped = 0;
    final n = await apply(data, onSkipped: (s) => skipped = s);
    SyncConfig.profile = target;
    SyncConfig.rev = rev;
    SyncConfig.lastSyncAt = DateTime.now().millisecondsSinceEpoch;
    status.value = skipped > 0
        ? '已拉取 rev $rev，应用 $n 项，跳过 $skipped 项（远端是旧格式，缺类型信息；在常用设备上重新上传一次即可）'
        : '已拉取 rev $rev，应用 $n 项';
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
    // 关键：忽略同步自己的记账键。
    // push()/pull() 会写 mod_sync_rev、mod_sync_last_at，而它们也在 setting box 里，
    // 不排除的话：上传 → 写 rev → 触发本监听 → 又上传 …… 无限循环；
    // 循环期间 busy 一直为 true，定时拉取会被 if (busy.value) return 整个饿死，
    // 表现就是"自动下发永远不生效"（实测踩到，rev 一路涨到 37）。
    final key = event.key?.toString() ?? '';
    if (key.startsWith('mod_sync_') || key == 'mod_local_videos') return;
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
