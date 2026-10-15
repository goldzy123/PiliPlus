import 'dart:async';

import 'package:PiliPlus/mod/diagnostics/mod_log.dart';
import 'package:flutter/foundation.dart';
import 'package:media_kit/media_kit.dart';

/// 播放健康看门狗：**在播但画面/时钟不前进时自动救回来**。
///
/// 覆盖两类失效，症状都是「声音还在继续，画面冻住，只能退出重进」：
///
///  1. **时钟停住** —— mpv 的 `time-pos` 不再前进（音频后端 flush/重建后
///     `AAudioStream_getTimestamp()` 返回异常值，音频时钟随之卡死）。
///  2. **画面停住** —— 时钟在走，但视频输出不出帧（surface 重建、外接屏丢失）。
///
/// ## v2：为什么重写（2026-10-15）
///
/// v1 在弱机（车机骁龙665）上**完全不可用**：刚开始播、还在缓冲就被判成
/// 「画面停住」，触发自愈（seek/切视频轨）→ 播放被打断 → 又开始缓冲 →
/// 再次误判，无限循环。
///
/// v1 的三个错误：
///
///  a) **把启动/缓冲期当成卡死**。`vo-configured` 在视频输出还没配好时就是
///     `false`，`estimated-vf-fps` 是滑动平均、刚起播（或刚 seek）时也是 0 ——
///     这两个信号在起播头几秒必然"看起来像卡死"。v1 只等 3 秒就动手。
///  b) **用 app 层的 isBuffering 判缓冲**。它只在 PiliPlus 自己认为在缓冲时
///     为真，mpv 真正因缓存不足而暂停（`paused-for-cache`）时它可能是 false。
///  c) **自愈后不设冷却、不限次数**。救不回来的情况下会一直循环。
///
/// v2 的对策：
///
///  a) **预热期**：起播/seek/自愈之后一段时间内（默认 12 秒）只看不判。
///  b) **用 mpv 自己的缓冲信号**：`paused-for-cache`、`cache-buffering-state`、
///     `demuxer-cache-idle` —— 这三个是权威判据（本地 mpv 实测属性存在）。
///     只要在缓冲就一律不算卡死。
///  c) **判定窗口拉长**：时钟停 5 秒、画面停 8 秒才算；而且"画面停住"要求
///     时钟**仍在前进**（那才是"声音在走画面冻住"的定义）。
///  d) **自愈后冷却 + 次数上限**：默认冷却 30 秒、每次播放最多救 3 次；
///     救不动就放弃（宁可卡着，也不要反复打断播放）。
///
/// 判断依据（本地 mpv 实测确认）：
///  · `time-pos` 静止 → 时钟停住。
///  · `vo-configured` = false 或 `estimated-vf-fps` ≈ 0 → 画面停住。
///    **`estimated-frame-number` 不能用** —— 它由 time-pos 推算，画面冻住照样涨。
///  · 纯音频内容（从没出现过视频轨）跳过画面检查。
class PlaybackWatchdog {
  PlaybackWatchdog({
    required this.player,
    required this.isPlaying,
    required this.isBusy,
    required this.onHardStall,
    this.onHealed,
    this.interval = const Duration(seconds: 1),
    this.clockStillTicks = 5,
    this.videoStillTicks = 8,
    this.warmup = const Duration(seconds: 12),
    this.cooldown = const Duration(seconds: 30),
    this.maxHeals = 3,
  });

  final Player player;

  /// 是否处于「应该正在播」的状态（暂停/结束时要返回 false）
  final bool Function() isPlaying;

  /// app 层认为的 seek / 缓冲（作为 mpv 信号的补充）
  final bool Function() isBusy;

  /// 三级手段都无效时回调，由上层重新取流并回到该位置
  final void Function(Duration position) onHardStall;

  /// 自愈动作的可观测回调（用于日志/提示）
  final void Function(String reason)? onHealed;

  final Duration interval;

  /// 时钟连续静止多少个采样周期才算卡死
  final int clockStillTicks;

  /// 画面连续不出帧多少个采样周期才算卡死（比时钟宽松：弱机掉帧是常态）
  final int videoStillTicks;

  /// 起播/seek/自愈之后的"只看不判"时间
  final Duration warmup;

  /// 一次自愈之后多久内不再动手
  final Duration cooldown;

  /// 每次播放最多自愈几次（防止救不回来时无限循环）
  final int maxHeals;

  Timer? _timer;
  double _lastPos = -1;
  int _posStill = 0;
  int _videoStill = 0;
  int _stage = 0;
  bool _healing = false;

  /// 预热截止时间 / 冷却截止时间 / 已自愈次数
  DateTime _quietUntil = DateTime.fromMillisecondsSinceEpoch(0);
  DateTime _nextHealAt = DateTime.fromMillisecondsSinceEpoch(0);
  int _healCount = 0;

  /// 这个媒体有没有视频轨。只在真的出现过视频轨时置位，
  /// 这样纯音频内容不会被误判成「画面停住」。
  bool _sawVideo = false;

  void start() {
    _timer ??= Timer.periodic(interval, (_) => unawaited(_tick()));
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
    _reset();
  }

  /// seek / 切集 / 换清晰度之后调用：丢掉旧状态重新观察。
  ///
  /// 注意这里**要重新预热** —— seek 之后 vo/fps 同样要几秒才稳定。
  void kick() {
    _reset();
    _quietUntil = DateTime.now().add(warmup);
  }

  void _reset() {
    _lastPos = -1;
    _posStill = 0;
    _videoStill = 0;
    _stage = 0;
  }

  static double _num(Player p, String prop) {
    try {
      final raw = p.getProperty(prop);
      if (raw.isEmpty) return -1;
      return double.tryParse(raw) ?? -1;
    } catch (_) {
      return -1;
    }
  }

  /// 读一个 flag 属性（mpv 返回 "yes"/"no"）
  static bool? _flag(Player p, String prop) {
    try {
      final raw = p.getProperty(prop).trim();
      if (raw == 'yes') return true;
      if (raw == 'no') return false;
      return null;
    } catch (_) {
      return null;
    }
  }

  /// mpv 自己是不是在等缓存。用它的权威信号，而不是 app 层的猜测。
  bool _mpvBuffering(Player p) {
    if (_flag(p, 'paused-for-cache') == true) return true;
    if (_flag(p, 'demuxer-cache-idle') == true) return true;
    // cache-buffering-state: 100 = 缓存充足；低于 100 说明在填缓存
    final cbs = _num(p, 'cache-buffering-state');
    if (cbs >= 0 && cbs < 100) return true;
    return false;
  }

  Future<void> _tick() async {
    if (_healing) return;
    final p = player;

    if (!isPlaying() || isBusy()) {
      _reset();
      return;
    }

    // 预热期 / 冷却期：只观察不判定。
    // 起播和 seek 之后 vo-configured、estimated-vf-fps 都需要几秒才稳定，
    // v1 就是在这里误判的（车机上表现成"刚开始缓冲就说掉帧，然后反复重启"）。
    final now = DateTime.now();
    if (now.isBefore(_quietUntil) || now.isBefore(_nextHealAt)) {
      _lastPos = -1;
      _posStill = 0;
      _videoStill = 0;
      return;
    }

    // 正在等缓存 → 画面本来就不动，这不算卡死
    if (_mpvBuffering(p)) {
      _reset();
      return;
    }

    final pos = _num(p, 'time-pos');
    if (pos < 0) return;

    if (!_sawVideo) {
      try {
        if (player.state.tracks.video.isNotEmpty) _sawVideo = true;
      } catch (_) {}
    }

    // ── 时钟 ──────────────────────────────────────────────
    if (_lastPos >= 0 && (pos - _lastPos).abs() < 0.05) {
      _posStill++;
    } else {
      _posStill = 0;
    }
    _lastPos = pos;

    // ── 画面 ──────────────────────────────────────────────
    if (_sawVideo) {
      final voOk = _flag(p, 'vo-configured');
      final fps = _num(p, 'estimated-vf-fps');
      final stalled = voOk == false || (fps >= 0 && fps < 0.5);
      if (stalled) {
        _videoStill++;
      } else {
        _videoStill = 0;
      }
    } else {
      // 音频内容没有视频轨，不检查画面
      _videoStill = 0;
    }

    // 时钟停住 → 独立判据
    if (_posStill >= clockStillTicks) {
      await _heal('播放时钟停住', pos);
      return;
    }

    // 画面停住 → 必须**时钟仍在走**（这才是"声音在走画面冻住"）；
    // 时钟也不动的情况上面已经处理了。
    if (_videoStill >= videoStillTicks && _posStill == 0) {
      await _heal('画面输出停住', pos);
    }
  }

  Future<void> _heal(String reason, double pos) async {
    if (_healCount >= maxHeals) {
      // 救不动了就别再打断播放 —— 反复重启比卡着更糟
      _nextHealAt = DateTime.now().add(const Duration(days: 1));
      _say('$reason → 已达自愈次数上限（$maxHeals 次），停止干预');
      return;
    }

    _healing = true;
    try {
      final target = Duration(
        milliseconds: ((pos > 0 ? pos : 0) * 1000).round(),
      );
      _healCount++;
      switch (_stage) {
        case 0:
          _stage = 1;
          // ① 原地刷新 seek：mpv 重新 flush，时钟和画面通常都能回来
          try {
            await player.seek(target);
          } catch (_) {}
          _say('$reason → 已原地刷新');
        case 1:
          _stage = 2;
          // ② 切一次视频轨，强制重建视频输出
          try {
            await player.setVideoTrack(VideoTrack.no());
            await Future<void>.delayed(const Duration(milliseconds: 300));
            await player.setVideoTrack(VideoTrack.auto());
          } catch (_) {}
          _say('$reason → 已重建画面');
        default:
          _stage = 0;
          // ③ 交给上层重新取流
          _say('$reason → 重新取流');
          try {
            onHardStall(target);
          } catch (_) {}
      }
    } finally {
      // 无论哪一级，都重新预热 + 进冷却，别拿旧采样立刻又判定卡死
      _reset();
      _quietUntil = DateTime.now().add(warmup);
      _nextHealAt = DateTime.now().add(cooldown);
      _healing = false;
    }
  }

  void _say(String why) {
    if (kDebugMode) debugPrint('[playback-watchdog] $why');
    ModLog.write('watchdog', why);
    onHealed?.call(why);
  }
}
