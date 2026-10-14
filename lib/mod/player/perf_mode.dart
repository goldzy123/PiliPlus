import 'dart:io';

import 'package:PiliPlus/utils/storage.dart';

/// 弱机 / 车机性能模式。
///
/// 面向骁龙 665 这类弱 SoC（车机常见）。默认关，因为好设备上这些取舍是负收益。
///
/// ## 为什么需要单独一个模式
///
/// PiliPlus 默认把 `--video-sync` 设成 **`display-resample`**。mpv 手册对这个模式的
/// 评价是「鲁棒性不足，依赖一些理想化假设」—— 它会按屏幕刷新率**重采样音频**并微调
/// 视频速度，弱机上就是持续卡顿的来源。而且这一类 `display-*` 模式下 `--framedrop`
/// 只影响"丢帧还是重复帧"，并不能让解码器少干活。
///
/// 弱机真正需要的是：**音频当主时钟，画面跟不上就丢帧**。这正是 mpv 的 `audio`
/// 模式（也是 mpv 自己的默认），配合 `framedrop=decoder+vo` 让解码器在解码前就跳过
/// 过期帧 —— 省的是真正的 CPU，而不只是省渲染。
///
/// 注意 mpv 手册**不推荐** `decoder` / `decoder+vo`（原话：可能产生"无法观看的卡顿，
/// 甚至彻底冻住画面"）。所以这里做成可选：宁可卡顿但音画同步，也好过完全播不动。
///
/// ## 各项取舍
///
/// | 选项 | 默认 | 这里 | 原因 |
/// | --- | --- | --- | --- |
/// | `video-sync` | display-resample | `audio` | 不再重采样音频，音频为主时钟，画面丢帧跟随 |
/// | `framedrop` | `vo` | `decoder+vo` | 在**解码前**丢，才真的省 CPU；`vo` 模式还有个"低于 10fps 就停止丢帧"的行为 |
/// | `vd-lavc-framedrop` | `nonref` | `all` | 软解时更激进地丢 |
/// | `vd-lavc-skipframe` | `default` | `nonref` | 软解跳过非参考帧 |
/// | 缩放/抖动/插值 | spline36 等 | bilinear / 关 | 弱机 GPU（如 Adreno 610）省下来 |
/// | `deband` / `interpolation` | 关 | 显式关 | 这两个都是 GPU 大户，怕被别处打开 |
/// | `hdr-compute-peak` / `tone-mapping` | 开 / auto | 关 / clip | HDR 色调映射很贵 |
/// | 缓存 | 跟着用户设置（常见 64MB/64s） | 32MB/20s | 车机内存小，少一点拷贝和常驻 |
///
/// 另外强烈建议**关掉弹幕**：弹幕是 Flutter 层叠加渲染的，60fps 下和视频一起抢 GPU，
/// 在弱机上往往是压垮骆驼的最后一根稻草（这个在设置里单独关，不在这里强制）。
abstract final class ModPerfMode {
  static const key = 'mod_perf_mode';

  /// 用户在设置里的开关
  static bool get enabled {
    try {
      return GStorage.setting.get(key, defaultValue: false) as bool;
    } catch (_) {
      return false;
    }
  }

  static set enabled(bool v) => GStorage.setting.put(key, v);

  /// 粗判"这是台弱机"，用来在设置页给个提示（不自动开启）。
  ///
  /// 只按核数和架构猜，判不准 —— 所以**只用于提示文案**，不影响行为。
  static bool get looksWeak {
    if (!Platform.isAndroid) return false;
    try {
      return Platform.numberOfProcessors <= 8;
    } catch (_) {
      return false;
    }
  }

  /// 覆盖给 mpv 的选项。空 Map = 不干预。
  static Map<String, String> get mpvOptions {
    if (!enabled) return const {};
    return const {
      // 音频当主时钟；画面跟不上就丢帧（而不是去重采样音频）
      'video-sync': 'audio',
      // 解码前就丢过期帧 —— 弱机上真正省 CPU 的一档
      'framedrop': 'decoder+vo',
      'vd-lavc-framedrop': 'all',
      'vd-lavc-skipframe': 'nonref',
      // GPU 侧能省的全省
      'scale': 'bilinear',
      'cscale': 'bilinear',
      'dscale': 'bilinear',
      'tscale': 'oversample',
      'deband': 'no',
      'interpolation': 'no',
      'correct-downscaling': 'no',
      'linear-downscaling': 'no',
      'hdr-compute-peak': 'no',
      'tone-mapping': 'clip',
      // 车机内存小
      'demuxer-max-bytes': '33554432',
      'demuxer-max-back-bytes': '8388608',
      'cache-secs': '20',
    };
  }
}
