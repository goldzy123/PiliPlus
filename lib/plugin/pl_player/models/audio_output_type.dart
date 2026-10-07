import 'package:PiliPlus/models/common/enum_with_label.dart';

enum AudioOutput implements EnumWithLabel {
  opensles('OpenSL ES'),
  aaudio('AAudio'),
  audiotrack('AudioTrack'),
  ;

  static final defaultValue = values.map((e) => e.name).join(',');

  /// 计算传给 mpv 的 `--ao`。
  ///
  /// AAudio 后端在部分设备（三星 / MTK）上，seek 触发的 flush + restart 之后
  /// `AAudioStream_getTimestamp()` 会返回异常值，mpv 的音频时钟随之卡住：
  /// 表现为**拖动进度条后画面冻结、声音却还在继续**，且 release 版没有任何报错日志
  /// （实测三星 SM-G9810：冻结持续约 60 秒；音频输出改成 AudioTrack 后完全不复现）。
  /// 参考 bggRGjQaUbCoE/PiliPlus#2544、#2711，以及根因分析相同但未合并的 #2434。
  ///
  /// 所以这里永远不把 aaudio 放在首选位置：用户选了 aaudio 时把它排到最后，
  /// 只选了 aaudio 时补一个不依赖 HAL 时间戳的后端兜底。
  /// 对没有该问题的设备零影响（它们本来也不会真正用到 aaudio）。
  static String resolveMpvAo(String pref) {
    final list = pref.split(',').where((e) => e.isNotEmpty).toList();
    if (!list.contains(aaudio.name)) {
      return list.join(',');
    }
    final others = list.where((e) => e != aaudio.name).toList();
    if (others.isEmpty) {
      return '${opensles.name},${aaudio.name}';
    }
    return [...others, aaudio.name].join(',');
  }

  @override
  final String label;
  const AudioOutput(this.label);
}
