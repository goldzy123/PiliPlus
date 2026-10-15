import 'dart:io' show Platform;

import 'package:PiliPlus/models/video/play/url.dart' show Volume;
import 'package:PiliPlus/mod/diagnostics/mod_log.dart';
import 'package:PiliPlus/utils/storage_pref.dart';

enum AudioNormalization {
  disable('禁用'),
  // ref https://github.com/KRTirtho/spotube/commit/da10ab2e291d4ba4d3082b9a6ae535639fb8f1b7
  dynaudnorm('预设 dynaudnorm', 'dynaudnorm=g=15:f=500:m=6:r=0.9:p=0.9'),
  loudnorm('预设 loudnorm', 'loudnorm=I=-16:LRA=11:TP=-1.5'),
  custom('自定义参数'),
  ;

  final String title;
  final String param;
  const AudioNormalization(this.title, [this.param = '']);

  static String getTitleFromConfig(String config) => switch (config) {
    '0' => disable.title,
    '1' => dynaudnorm.title,
    '2' => loudnorm.title,
    _ => config,
  };

  static String getParamFromConfig(String config) => switch (config) {
    '0' => disable.param,
    '1' => dynaudnorm.param,
    '2' => loudnorm.param,
    _ => config,
  };

  static final loudnormRegExp = RegExp('loudnorm=([^,]+)');

  static String parse(Volume? volume, String param) {
    if (volume != null && volume.isNotEmpty) {
      return param.replaceFirstMapped(
        loudnormRegExp,
        (i) =>
            'loudnorm=${volume.format(
              Map.fromEntries(
                i.group(1)!.split(':').map((item) {
                  final parts = item.split('=');
                  return MapEntry(parts[0].toLowerCase(), num.parse(parts[1]));
                }),
              ),
            )}',
      );
    } else {
      return param.replaceFirst(
        loudnormRegExp,
        AudioNormalization.getParamFromConfig(Pref.fallbackNormalization),
      );
    }
  }
}

mixin AudioNormalizationMixin {
  late final _audioNormalization = Pref.audioNormalization;
  late final enableAudioNormalization =
      Platform.isAndroid && _audioNormalization != '0';
  late final _param = AudioNormalization.getParamFromConfig(
    _audioNormalization,
  );

  /// 用 `--af=lavfi=[滤镜]` 而不是 `--lavfi-complex="[aid1] 滤镜 [ao]"`。
  ///
  /// 为什么换（2026-10-15，用户报"响度均衡没落地"）：
  /// `lavfi-complex` 是**替换整条滤镜图**，必须显式引用音频轨标签 `[aid1]`；
  /// 而它只在 `dataSource.audioSource` 非空（视频带独立音频流）时才被调用 ——
  /// 一旦那条流不存在，整条图就没被设上，等于完全没生效，而且**没有任何提示**。
  /// `--af=lavfi=[...]` 是在音频滤镜链上追加，不需要引用轨道标签、也不挑流的形态，
  /// 是 mpv 里使用 libavfilter 滤镜的标准写法（本地 mpv 实测两种都能跑，
  /// 但 af 这种少一个失败条件）。
  static const _kNormalizationKey = 'af';

  Map<String, String>? audioFilterExtras(
    Volume? volume, {
    Map<String, String>? map,
  }) {
    ModLog.write('loud', 'enable=$enableAudioNormalization param=$_param');
    if (!enableAudioNormalization) return map;
    final audioNormalization = AudioNormalization.parse(volume, _param);
    if (audioNormalization.isEmpty) return map;
    // lavfi=[] 是 mpv 对 libavfilter 滤镜的包装；外层再套一对引号，
    // 避免参数里的逗号被 mpv 的 filter 分隔符拆开。
    final value = 'lavfi=[$audioNormalization]';
    if (map != null) {
      map[_kNormalizationKey] = value;
      return map;
    }
    return {_kNormalizationKey: value};
  }
}
