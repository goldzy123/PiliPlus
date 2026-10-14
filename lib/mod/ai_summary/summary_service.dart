import 'dart:convert';

import 'package:PiliPlus/models_new/video/video_play_info/subtitle.dart';
import 'package:PiliPlus/utils/storage.dart';
import 'package:dio/dio.dart';

/// 视频总结：B 站官方没给结论时，自己生成一份。
///
/// ## 现在的逻辑
///
/// PiliPlus 原来的「AI 总结」直接调 B 站官方的
/// `/x/web-interface/view/conclusion/get` —— 只有**B 站自己生成过**的视频才有货，
/// 大部分视频点进去什么都没有，看着就像"不好用"。
///
/// 这里的做法是分层的：
///
///   1. 官方有结论 → 直接用（质量最高，一分钱不花）；
///   2. 官方没有 → 取这个视频的**字幕**（自带字幕或官方 AI 字幕），
///      丢给局域网里 Mac 上的总结服务（mod/server/piliplus-summary-server.mjs），
///      它用 DSH 默认的 opencode-go / deepseek-v4.1-flash 生成；
///   3. 连字幕都没有 → Mac 那边退化成「yt-dlp 抓音频 + FunASR 转写」再总结；
///   4. 结果**两边都缓存**（手机 GStorage.localCache、Mac 落盘），
///      下次点开直接出，不再等。
///
/// ## 为什么 LLM 放 Mac 上
///
/// 手机上不存 API key，也不用为了总结跑一次大模型请求（费电、慢）。
/// 手机只负责"把字幕取出来"，那件事它本来就有登录态、最方便。
abstract final class ModSummaryService {
  static const _urlKey = 'mod_summary_url';
  static const _cachePrefix = 'mod_summary_';

  static final _dio = Dio(
    BaseOptions(
      connectTimeout: const Duration(seconds: 6),
      receiveTimeout: const Duration(minutes: 5),
    ),
  );

  /// Mac 上总结服务的地址，例如 `http://192.168.6.229:8721`
  static String get baseUrl {
    try {
      return (GStorage.setting.get(_urlKey, defaultValue: '') as String).trim();
    } catch (_) {
      return '';
    }
  }

  static set baseUrl(String v) =>
      GStorage.setting.put(_urlKey, v.trim().replaceAll(RegExp(r'/+$'), ''));

  static bool get configured => baseUrl.isNotEmpty;

  static String _cacheKey(String bvid, String cid) =>
      '$_cachePrefix${bvid}_$cid';

  /// 本地缓存（手机侧）。命中就不用联网了。
  static ModSummaryResult? cached(String bvid, String cid) {
    try {
      final raw = GStorage.localCache.get(_cacheKey(bvid, cid));
      if (raw is Map) {
        return ModSummaryResult.fromJson(Map<String, dynamic>.from(raw));
      }
    } catch (_) {}
    return null;
  }

  static Future<void> _save(String bvid, String cid, ModSummaryResult r) async {
    try {
      await GStorage.localCache.put(_cacheKey(bvid, cid), r.toJson());
    } catch (_) {}
  }

  /// 从播放信息里挑一份字幕并取出纯文本。
  ///
  /// 优先中文（含官方 AI 字幕），实在没有再退而求其次。取回来的是
  /// B 站字幕 JSON（`body[].content`），这里拼成连续文本交给 LLM ——
  /// 比 VTT 少了时间轴噪声，同样的 token 能装下更多内容。
  static Future<String?> fetchSubtitleText(List<Subtitle> list) async {
    if (list.isEmpty) return null;
    final best = _pickSubtitle(list);
    final url = best.subtitleUrlV2 ?? best.subtitleUrl;
    if (url == null || url.isEmpty) return null;
    try {
      final res = await _dio.get<dynamic>(
        url.startsWith('http') ? url : 'https:$url',
        options: Options(responseType: ResponseType.json),
      );
      final body = (res.data is Map ? res.data['body'] : null);
      if (body is! List) return null;
      final sb = StringBuffer();
      for (final item in body) {
        if (item is Map && item['content'] != null) {
          final t = '${item['content']}'.trim();
          if (t.isNotEmpty) sb.write(t);
        }
      }
      final text = sb.toString().trim();
      return text.length < 30 ? null : text;
    } catch (_) {
      return null;
    }
  }

  static Subtitle _pickSubtitle(List<Subtitle> list) {
    // 中文优先，AI 字幕其次
    for (final s in list) {
      if (s.lan.contains('zh') && !s.isAi) return s;
    }
    for (final s in list) {
      if (s.lan.contains('zh')) return s;
    }
    return list.first;
  }

  /// 让 Mac 生成总结。命中的优先级：手机缓存 → Mac 缓存 → 现算。
  static Future<ModSummaryResult?> generate({
    required String bvid,
    required String cid,
    String title = '',
    String upName = '',
    String? subtitleText,
    bool force = false,
  }) async {
    if (!configured) return null;
    if (!force) {
      final hit = cached(bvid, cid);
      if (hit != null) return hit;
    }
    try {
      final res = await _dio.post<dynamic>(
        '$baseUrl/api/summary',
        data: {
          'bvid': bvid,
          'cid': cid,
          'title': title,
          'upName': upName,
          if (subtitleText != null && subtitleText.isNotEmpty)
            'subtitleText': subtitleText,
          if (force) 'force': true,
        },
        options: Options(
          responseType: ResponseType.json,
          contentType: Headers.jsonContentType,
        ),
      );
      final d = res.data;
      if (d is! Map) return null;
      if (d['ok'] == false) {
        // 没有字幕、转写失败之类 —— 交给调用方决定怎么提示
        return ModSummaryResult(
          summary: '',
          source: '${d['reason'] ?? 'failed'}',
          failed: true,
        );
      }
      final r = ModSummaryResult.fromJson(Map<String, dynamic>.from(d));
      if (r.summary.isNotEmpty) await _save(bvid, cid, r);
      return r;
    } catch (_) {
      return null;
    }
  }

  /// 取字幕 + 生成，一步到位（给 UI 用）。
  ///
  /// [subtitles] 直接来自 VideoDetailController.subtitles —— 视频页已经拿到的
  /// 字幕列表（含官方 AI 字幕），不用再请求一次播放地址。
  static Future<ModSummaryResult?> generateFor({
    required String bvid,
    required String cid,
    List<Subtitle>? subtitles,
    String title = '',
    String upName = '',
    bool force = false,
  }) async {
    if (!configured) return null;
    if (!force) {
      final hit = cached(bvid, cid);
      if (hit != null) return hit;
    }
    String? text;
    if (subtitles != null && subtitles.isNotEmpty) {
      text = await fetchSubtitleText(subtitles);
    }
    return generate(
      bvid: bvid,
      cid: cid,
      title: title,
      upName: upName,
      subtitleText: text,
      force: force,
    );
  }

  static String decodeBody(dynamic data) =>
      data is String ? data : jsonEncode(data);
}

/// 一份总结结果。
class ModSummaryResult {
  final String summary;
  final String source;
  final bool failed;
  final int? at;
  final int? chars;

  const ModSummaryResult({
    required this.summary,
    this.source = '',
    this.failed = false,
    this.at,
    this.chars,
  });

  factory ModSummaryResult.fromJson(Map<String, dynamic> j) => ModSummaryResult(
    summary: '${j['summary'] ?? ''}',
    source: '${j['source'] ?? ''}',
    at: j['at'] is int ? j['at'] as int : null,
    chars: j['chars'] is int ? j['chars'] as int : null,
  );

  Map<String, dynamic> toJson() => {
    'summary': summary,
    'source': source,
    'at': at,
    'chars': chars,
  };

  /// 来源的中文说明，显示在面板底部
  String get sourceLabel => switch (source) {
    'subtitle' => '来自视频字幕',
    'asr' => '来自语音转写',
    'cache' => '来自缓存',
    'no_subtitle' => '这个视频没有字幕，也没能转写出内容',
    'text_too_short' => '字幕内容太短，总结不了',
    _ => source,
  };
}
