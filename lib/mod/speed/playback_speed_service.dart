import 'dart:convert';

import 'package:PiliPlus/utils/accounts.dart';
import 'package:PiliPlus/utils/storage.dart';
import 'package:PiliPlus/utils/storage_pref.dart';
import 'package:dio/dio.dart';
import 'package:hive_ce/hive.dart';

class SpeedRule {
  final String keyword;
  final double speed;

  const SpeedRule({required this.keyword, required this.speed});

  Map<String, dynamic> toJson() => {'keyword': keyword, 'speed': speed};

  factory SpeedRule.fromJson(Map<String, dynamic> json) => SpeedRule(
    keyword: json['keyword']?.toString() ?? '',
    speed: (json['speed'] as num?)?.toDouble() ?? 1.0,
  );
}

abstract final class PlaybackSpeedService {
  static Box get _video => GStorage.video;

  static String _scope(String key) {
    final mid = Accounts.main.isLogin ? Accounts.main.mid.toString() : 'anon';
    return '$mid|$key';
  }

  static Map<String, double> _videoSpeedMap() => Map<String, double>.from(
    _video.get(_scope('videoSpeedMap'), defaultValue: <String, double>{}),
  );

  static Map<String, double> _upSpeedMap() => Map<String, double>.from(
    _video.get(_scope('upSpeedMap'), defaultValue: <String, double>{}),
  );

  static Map<String, String> _upNameMap() => Map<String, String>.from(
    _video.get(_scope('upNameMap'), defaultValue: <String, String>{}),
  );

  static Map<String, String> _aiCategoryMap() => Map<String, String>.from(
    _video.get(_scope('aiCategoryMap'), defaultValue: <String, String>{}),
  );

  static double? videoSpeed(String bvid, int cid) =>
      _videoSpeedMap()['$bvid:$cid'];

  static double? upSpeed(int mid) => _upSpeedMap()[mid.toString()];

  static String? upName(int mid) => _upNameMap()[mid.toString()];

  static String? aiCategory(int mid) => _aiCategoryMap()[mid.toString()];

  static Map<String, double> get upOverrides => _upSpeedMap();

  static Future<void> saveVideoSpeed({
    required String bvid,
    required int cid,
    required double speed,
  }) async {
    final map = _videoSpeedMap();
    map['$bvid:$cid'] = speed;
    await _video.put(_scope('videoSpeedMap'), map);
  }

  static Future<void> setUpSpeed({
    required int mid,
    required double speed,
    String? name,
  }) async {
    final map = _upSpeedMap();
    map[mid.toString()] = speed;
    await _video.put(_scope('upSpeedMap'), map);
    if (name != null && name.isNotEmpty) {
      final nameMap = _upNameMap();
      nameMap[mid.toString()] = name;
      await _video.put(_scope('upNameMap'), nameMap);
    }
  }

  static Future<void> removeUpSpeed(int mid) async {
    final map = _upSpeedMap()..remove(mid.toString());
    await _video.put(_scope('upSpeedMap'), map);
  }

  static double resolveSpeed({
    String? bvid,
    int? cid,
    int? upMid,
    String? upName,
    String? title,
  }) {
    if (upMid != null) {
      final upSpeedValue = upSpeed(upMid);
      if (upSpeedValue != null) return upSpeedValue;
    }
    if (bvid != null && cid != null) {
      final videoSpeedValue = videoSpeed(bvid, cid);
      if (videoSpeedValue != null) return videoSpeedValue;
    }
    final ruleSpeed = _matchRule(upName: upName, title: title);
    if (ruleSpeed != null) return ruleSpeed;
    if (upMid != null) {
      final category = aiCategory(upMid);
      if (category != null) {
        final categorySpeed = Pref.speedAiCategoryMap[category];
        if (categorySpeed != null) return categorySpeed;
      }
    }
    return Pref.playSpeedDefault;
  }

  static double? _matchRule({String? upName, String? title}) {
    final source = '${upName ?? ''} ${title ?? ''}';
    for (final rule in Pref.speedRules) {
      final keyword = rule['keyword']?.toString() ?? '';
      final speed = (rule['speed'] as num?)?.toDouble();
      if (keyword.isEmpty || speed == null) continue;
      if (source.contains(keyword)) return speed;
    }
    return null;
  }

  /// 未命中本地规则时异步调用用户配置的 AI 接口并缓存分类结果。
  static Future<void> warmAi({
    int? upMid,
    String? upName,
    String? title,
  }) async {
    if (upMid == null || !Pref.enableSpeedAi || aiCategory(upMid) != null) {
      return;
    }
    final baseUrl = Pref.speedAiBaseUrl.trim();
    final apiKey = Pref.speedAiApiKey.trim();
    final model = Pref.speedAiModel.trim();
    if (baseUrl.isEmpty || apiKey.isEmpty || model.isEmpty) return;

    final category = await _classifyWithAi(
      baseUrl: baseUrl,
      apiKey: apiKey,
      model: model,
      upName: upName,
      title: title,
    );
    if (category == null) return;

    final map = _aiCategoryMap();
    map[upMid.toString()] = category;
    await _video.put(_scope('aiCategoryMap'), map);
  }

  static Future<String?> _classifyWithAi({
    required String baseUrl,
    required String apiKey,
    required String model,
    String? upName,
    String? title,
  }) async {
    try {
      final endpoint = baseUrl.endsWith('/')
          ? '${baseUrl}chat/completions'
          : '$baseUrl/chat/completions';
      final categories = Pref.speedAiCategoryMap.keys.join('、');
      final response = await Dio().post(
        endpoint,
        data: {
          'model': model,
          'temperature': 0,
          'messages': [
            {
              'role': 'system',
              'content':
                  '你是视频分类助手。只返回 JSON，格式为 '
                  '{"category":"类别名"}，不要输出其他内容。',
            },
            {
              'role': 'user',
              'content':
                  'UP主：${upName ?? "未知"}，视频标题：'
                  '${title ?? "未知"}。可选类别：$categories。',
            },
          ],
        },
        options: Options(
          headers: {
            'Authorization': 'Bearer $apiKey',
            'Content-Type': 'application/json',
          },
          sendTimeout: const Duration(seconds: 3),
          receiveTimeout: const Duration(seconds: 5),
        ),
      );
      final raw = response.data?['choices']?[0]?['message']?['content'];
      if (raw is! String || raw.isEmpty) return null;
      final decoded = jsonDecode(raw);
      if (decoded is Map<String, dynamic>) {
        return decoded['category']?.toString();
      }
      return null;
    } catch (_) {
      return null;
    }
  }
}
