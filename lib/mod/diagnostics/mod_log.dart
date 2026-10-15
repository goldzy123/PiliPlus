import 'dart:io';

import 'package:path_provider/path_provider.dart';

/// release 包里的诊断日志。
///
/// 为什么需要它：Dart 的 `print` 在 release 构建里**不会进 logcat**
/// （`log.redirect-stdio` 是只读属性、改不了；logcat 里那些 `I flutter :`
/// 是 Flutter 引擎自己的 native 日志，不是 Dart 输出）。
/// 所以要在真机上查"某个分支到底走没走到"，只能写文件。
///
/// 落盘位置：应用私有目录 `files/mod_debug.log`，root 下可直接读：
///   adb shell su -c 'cat /data/data/<pkg>/files/mod_debug.log'
///
/// 只在编译期常量开关打开时写，避免平时白白占 IO。
abstract final class ModLog {
  /// 需要临时排查时把它改成 true 再构建。
  static const enabled = false;

  static const _maxBytes = 256 * 1024;

  static File? _file;

  static Future<void> _ensure() async {
    if (_file != null) return;
    final dir = await getApplicationSupportDirectory();
    _file = File('${dir.path}/mod_debug.log');
  }

  static Future<void> write(String tag, Object? message) async {
    if (!enabled) return;
    try {
      await _ensure();
      final f = _file!;
      if (await f.exists() && await f.length() > _maxBytes) {
        await f.writeAsString('', mode: FileMode.write);
      }
      await f.writeAsString(
        '${DateTime.now().toIso8601String()} [$tag] $message\n',
        mode: FileMode.append,
        flush: true,
      );
    } catch (_) {
      // 诊断日志失败绝不能影响播放
    }
  }
}
