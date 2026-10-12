import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:media_kit/media_kit.dart';

/// 播放健康看门狗：**在播但画面/时钟不前进时自动救回来**。
///
/// 覆盖两类失效，症状都是「声音还在继续，画面冻住，只能退出重进」：
///
///  1. **时钟停住** —— mpv 的 `time-pos` 不再前进。
///     音频后端（尤其 AAudio，见 `AudioOutput.resolveMpvAo`）在 seek 触发的
///     flush+restart 之后、或切后台回来音频设备被重建之后，
///     `AAudioStream_getTimestamp()` 会返回异常值，mpv 的音频时钟随之卡死。
///  2. **画面停住** —— 时钟在走，但视频输出不出帧。
///     切后台回来 surface 被重建、或外接屏/DeX 下 surface 丢失时会出现。
///     这种情况**只看进度是发现不了的**（进度一直在走），必须看视频输出本身。
///
/// 处理阶梯（一级不行才下一级）：
///   ① 原地刷新 seek —— 让 mpv 重新 flush，多数情况这一步就好了；
///   ② 切一次视频轨 —— 强制重建视频输出，救「画面停住」；
///   ③ 回调上层重新取流 —— 复用 controller 的 `onSeekStalled`。
///
/// 判断依据说明：
///  · `time-pos` 静止 → 时钟停住。只在「正在播放且不在 seek/缓冲」时判定，
///    所以暂停、缓冲、拖动过程中都不会误判。
///  · `vo-configured` = false，或 `estimated-vf-fps` ≈ 0 → 画面停住。
///    这两个信号是在本地 mpv 上实测确认的：把视频轨一关（等价于"音频在走、
///    视频不出帧"），`vo-configured` 立刻变 false、`video-format` 变不可用，
///    而 `time-pos` 照常前进。**注意 `estimated-frame-number` 不能用** ——
///    它由 time-pos 推算，画面冻住它照样在涨。
///  · 纯音频内容（从没出现过视频轨）跳过画面检查。
class PlaybackWatchdog {
  PlaybackWatchdog({
    required this.player,
    required this.isPlaying,
    required this.isBusy,
    required this.onHardStall,
    this.onHealed,
    this.interval = const Duration(seconds: 1),
    this.stillTicks = 3,
  });

  final Player player;

  /// 是否处于「应该正在播」的状态（暂停/结束时要返回 false）
  final bool Function() isPlaying;

  /// 是否正在 seek / 缓冲（这些期间进度本来就不动，不能算卡死）
  final bool Function() isBusy;

  /// 三级手段都无效时回调，由上层重新取流并回到该位置
  final void Function(Duration position) onHardStall;

  /// 自愈动作的可观测回调（用于日志/提示）
  final void Function(String reason)? onHealed;

  final Duration interval;

  /// 连续多少个采样周期没动才算卡死
  final int stillTicks;

  Timer? _timer;
  double _lastPos = -1;
  int _posStill = 0;
  int _videoStill = 0;
  int _stage = 0;
  bool _healing = false;

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

  /// seek / 切集 / 换清晰度之后调用：丢掉旧状态重新观察
  void kick() => _reset();

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

  Future<void> _tick() async {
    if (_healing) return;
    final p = player;

    if (!isPlaying() || isBusy()) {
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
    // 判据用实测确认过的两个信号（本地 mpv 验证：视频轨一停，vo-configured 立刻
    // 变 false、video-format 变不可用，而 time-pos 照常前进 —— 正是"声音在走画面冻住"）：
    //   · vo-configured = false（有视频轨却没配置视频输出）
    //   · estimated-vf-fps ≈ 0（滤镜链不再出帧）
    // 注意 `estimated-frame-number` 不能用：它是由 time-pos 推算的，
    // 画面冻住它照样在涨（实测过）。
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

    if (_posStill < stillTicks && _videoStill < stillTicks) return;

    final clockStuck = _posStill >= stillTicks;
    await _heal(clockStuck ? '播放时钟停住' : '画面输出停住', pos);
  }

  Future<void> _heal(String reason, double pos) async {
    _healing = true;
    try {
      final target = Duration(
        milliseconds: ((pos > 0 ? pos : 0) * 1000).round(),
      );
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
      // 无论哪一级，都重新开始观察（别拿旧的采样值立刻又判定卡死）
      _lastPos = -1;
      _posStill = 0;
      _videoStill = 0;
      _healing = false;
    }
  }

  void _say(String why) {
    if (kDebugMode) debugPrint('[playback-watchdog] $why');
    onHealed?.call(why);
  }
}
