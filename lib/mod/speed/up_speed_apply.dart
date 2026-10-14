import 'dart:async';

import 'package:PiliPlus/mod/speed/playback_speed_service.dart';
import 'package:PiliPlus/pages/common/common_intro_controller.dart';
import 'package:PiliPlus/pages/video/controller.dart';

/// 「UP 强制倍速」的落地器。
///
/// ## 原来的问题
///
/// UP 倍速原本只在**取流那一刻**解析一次，而 upMid 是从介绍页控制器里拿的 ——
/// 介绍详情是异步加载的，取流时它往往还没到，于是 upMid 为 null，UP 强制倍速
/// 就没生效；外面还包着 try/catch，失败得无声无息。表现就是「有时候生效、
/// 有时候不生效」，而且不同入口（首页/搜索/收藏/相关推荐/UP 主页/连播…）
/// 因为时序不同，结果还不一样。
///
/// ## 现在的做法
///
/// 改成**不依赖某一个时机**，三条腿一起兜：
///
///   1. 取流时先按已知信息设一次（保持原行为）；
///   2. 监听介绍详情 —— 它一到位就补一次；
///   3. 起一个短时轮询（每 2 秒、最多 30 秒）继续尝试，直到成功或超时。
///      这样不管 upMid 是"马上就有"还是"十几秒后才来"、也不管中间经过
///      多少层页面，最终都会落到正确的倍速上。
///
/// ## 不覆盖用户的手动选择
///
/// 只要**用户自己**改过倍速（快捷按钮、官方倍速菜单，都会走
/// `PlPlayerController.setPlaybackSpeed`），就记为"用户已接管"，
/// 后续不再自动覆盖。判断依据有两条：
///   · 当前倍速已经不等于取流时自动设定的那个值；
///   · 或者收到过用户手动的倍速变更（[markUserTouched]）。
abstract final class UpSpeedApply {
  /// 成功补过的视频（bvid:cid）
  static final _done = <String>{};

  /// 用户手动改过倍速的视频
  static final _userTouched = <String>{};

  /// 详情监听
  static final _subs = <String, StreamSubscription<dynamic>>{};

  /// 短时轮询兜底
  static final _timers = <String, Timer>{};

  /// 正在由本模块自动设置倍速（此时 setPlaybackSpeed 不算用户操作）
  static bool isAutoApplying = false;

  static String keyOf(String? bvid, int? cid) => '${bvid ?? ''}:${cid ?? 0}';

  /// 用户手动改倍速了 —— 这个视频后续不再被 UP 规则覆盖。
  static void markUserTouched(String? bvid, int? cid) {
    if (isAutoApplying) return;
    _userTouched.add(keyOf(bvid, cid));
  }

  /// 在取流时调用。
  ///
  /// [autoSpeed] 是这次取流自动设定的倍速，用来判断用户后来有没有手动改过。
  static void arm({
    required VideoDetailController ctr,
    required double? autoSpeed,
  }) {
    final key = keyOf(ctr.bvid, ctr.cid.value);
    _release(key);

    final CommonIntroController? intro;
    try {
      intro = ctr.isUgc ? ctr.ugcIntroCtr : ctr.pgcIntroCtr;
    } catch (_) {
      return;
    }

    void tryApply() {
      if (_done.contains(key) || _userTouched.contains(key)) {
        _release(key);
        return;
      }
      final detail = intro!.videoDetail.value;
      final mid = detail.owner?.mid;
      if (mid == null) return;

      final player = ctr.plPlayerController;
      // 用户中途手动改过倍速 → 不覆盖（当前倍速已偏离取流时的自动值）
      if (autoSpeed != null &&
          (player.playbackSpeed - autoSpeed).abs() > 0.001) {
        _userTouched.add(key);
        _release(key);
        return;
      }

      final target = PlaybackSpeedService.resolveSpeed(
        bvid: ctr.bvid,
        cid: ctr.cid.value,
        upMid: mid,
        upName: detail.owner?.name,
        title: detail.title,
      );
      if (target <= 0) return;
      _done.add(key);
      _release(key);
      if ((player.playbackSpeed - target).abs() < 0.001) return;
      isAutoApplying = true;
      // save:false —— 这是 UP 规则带来的，不该被记成"这个视频的倍速"
      player.setPlaybackSpeed(target, save: false).whenComplete(() {
        isAutoApplying = false;
      });
    }

    tryApply(); // 详情可能早就到位了（缓存/连播）

    _subs[key] = intro.videoDetail.listen((_) => tryApply());

    // 兜底轮询：详情/播放器可能晚很久才就绪，覆盖所有入口
    var ticks = 0;
    _timers[key] = Timer.periodic(const Duration(seconds: 2), (t) {
      if (++ticks > 15) {
        _release(key);
        return;
      }
      tryApply();
    });
  }

  static void _release(String key) {
    _subs.remove(key)?.cancel();
    _timers.remove(key)?.cancel();
  }

  /// 视频页销毁时调用，别让监听/定时器堆积
  static void release(String? bvid, int? cid) {
    final key = keyOf(bvid, cid);
    _release(key);
    _done.remove(key);
    _userTouched.remove(key);
  }
}
