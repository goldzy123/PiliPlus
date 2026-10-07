import 'dart:async';

import 'package:PiliPlus/http/init.dart';
import 'package:PiliPlus/models/model_video.dart';
import 'package:PiliPlus/utils/date_utils.dart';
import 'package:PiliPlus/utils/storage.dart';
import 'package:get/get.dart';
import 'package:intl/intl.dart';
import 'package:material_ui/material_ui.dart';

/// 视频卡片的发布日期（mod）。
///
/// 背景：官方 app 端的推荐接口**完全不返回发布日期**——实测字段只有
/// `args=up_id,up_name,tid,tname,aid` 与 `player_args=aid,cid,type,duration`，
/// 顶层也没有 pubdate/ctime。所以 app 来源的推荐卡片一直没日期，而 web 来源
/// 和「热门」卡片有，看起来就是"有的显示有的不显示"。
///
/// 这里对缺日期的卡片按 bvid 补拉一次 `/x/web-interface/view`（不需要签名），
/// 结果长期缓存在 localCache 里，所以每支视频一辈子只多花一次请求。
abstract final class ModCardDate {
  static final shortFormat = DateFormat('M-d');
  static final longFormat = DateFormat('yy-M-d');

  static const _cachePrefix = 'mod_pubdate_';
  static const _maxConcurrent = 3;
  static const _retryAfter = Duration(minutes: 10);

  /// bvid -> pubdate（秒）
  static final _cache = <String, int>{}.obs;
  static final _pending = <String>{};
  static final _failedAt = <String, DateTime>{};
  static int _running = 0;

  /// 卡片右下角的日期；没有就返回空（不占位）。
  ///
  /// 返回值必须**含 `Spacer`**：它要顶到播放量/弹幕数的右侧，
  /// 所以由本方法整体接管卡片这一行的尾部。
  static List<Widget> statTrailing({
    required ThemeData theme,
    required BaseVideoItemModel item,
  }) {
    final direct = item.pubdate;
    if (direct != null && direct > 0) {
      return [const Spacer(), _text(theme, direct)];
    }
    final bvid = item.bvid;
    if (bvid == null || bvid.isEmpty) return const [];
    return [
      const Spacer(),
      Obx(() {
        final v = _cache[bvid] ?? _loadCached(bvid);
        if (v == null) {
          _schedule(bvid);
          return const SizedBox.shrink();
        }
        return _text(theme, v);
      }),
    ];
  }

  static Widget _text(ThemeData theme, int pubdate) {
    return Padding(
      padding: const EdgeInsets.only(left: 6, right: 2),
      child: Text(
        DateFormatUtils.dateFormat(
          pubdate,
          short: shortFormat,
          long: longFormat,
        ),
        maxLines: 1,
        style: TextStyle(
          fontSize: theme.textTheme.labelSmall!.fontSize,
          color: theme.colorScheme.outline.withValues(alpha: 0.8),
        ),
      ),
    );
  }

  static int? _loadCached(String bvid) {
    final v = GStorage.localCache.get('$_cachePrefix$bvid');
    if (v is int && v > 0) {
      _cache[bvid] = v;
      return v;
    }
    return null;
  }

  static void _schedule(String bvid) {
    if (_pending.contains(bvid)) return;
    final failed = _failedAt[bvid];
    if (failed != null && DateTime.now().difference(failed) < _retryAfter) {
      return;
    }
    _pending.add(bvid);
    unawaited(_fetch(bvid));
  }

  static Future<void> _fetch(String bvid) async {
    // 简单限流：一次最多 3 个在飞
    while (_running >= _maxConcurrent) {
      await Future<void>.delayed(const Duration(milliseconds: 150));
    }
    _running++;
    try {
      final res = await Request().get(
        '/x/web-interface/view',
        queryParameters: {'bvid': bvid},
      );
      final data = res.data;
      if (data is Map && data['code'] == 0) {
        final pubdate = (data['data'] as Map?)?['pubdate'];
        if (pubdate is int && pubdate > 0) {
          _cache[bvid] = pubdate;
          await GStorage.localCache.put('$_cachePrefix$bvid', pubdate);
        }
      }
    } catch (_) {
      // 记下失败时间，10 分钟内不再重试，避免列表滚动时反复打接口
      _failedAt[bvid] = DateTime.now();
    } finally {
      _running--;
      _pending.remove(bvid);
    }
  }
}
