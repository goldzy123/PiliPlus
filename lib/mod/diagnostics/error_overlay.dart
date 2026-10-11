import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'package:PiliPlus/utils/storage.dart';

/// 把 Flutter 的「灰方块」换成能读的异常文本。
///
/// 为什么需要它：release 包里 widget 构建抛异常时，Flutter 只画一个纯灰方块，
/// 不打印任何日志。遇到"整个页面变灰"这种问题时，在**没有 root、也没法看
/// logcat** 的设备上（比如三星 S20）就完全无从下手——只能靠猜。
///
/// 装上这个之后，同样的异常会把异常信息和调用栈直接画在屏幕上，截个图就能定位。
/// 想关掉：设置里加 `mod_error_overlay = false`（或在设置页关开关）。
abstract final class ModErrorOverlay {
  static const _key = 'mod_error_overlay';

  static bool get enabled {
    try {
      return GStorage.setting.get(_key, defaultValue: true) as bool;
    } catch (_) {
      // 极早期调用时 box 可能还没打开，此时按"开"处理
      return true;
    }
  }

  static set enabled(bool value) {
    GStorage.setting.put(_key, value);
  }

  /// 在 runApp 之前调用。
  static void install() {
    if (!enabled) return;
    final prev = ErrorWidget.builder;
    ErrorWidget.builder = (FlutterErrorDetails details) {
      // 别把 Flutter 自己的框架内部错误也吃掉
      if (!kReleaseMode) return prev(details);
      return _ModErrorCard(details: details);
    };
  }
}

class _ModErrorCard extends StatelessWidget {
  const _ModErrorCard({required this.details});

  final FlutterErrorDetails details;

  @override
  Widget build(BuildContext context) {
    final err = details.exceptionAsString();
    final stack = details.stack?.toString() ?? '';
    // 栈只留前若干行，够定位就行
    final frames = stack
        .split('\n')
        .where((l) => l.trim().isNotEmpty)
        .take(12)
        .join('\n');
    return Directionality(
      textDirection: TextDirection.ltr,
      child: Container(
        color: const Color(0xFF101010),
        padding: const EdgeInsets.fromLTRB(12, 40, 12, 12),
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'MOD 错误浮层（截图发我即可）',
                style: TextStyle(
                  color: Color(0xFFFF6B6B),
                  fontSize: 13,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 8),
              SelectableText(
                err,
                style: const TextStyle(
                  color: Color(0xFFFFD166),
                  fontSize: 12,
                  height: 1.35,
                ),
              ),
              const SizedBox(height: 12),
              const Text(
                '--- 调用栈（前 12 行）---',
                style: TextStyle(color: Color(0xFF8AB4F8), fontSize: 11),
              ),
              const SizedBox(height: 4),
              SelectableText(
                frames,
                style: const TextStyle(
                  color: Color(0xFFBBBBBB),
                  fontSize: 10,
                  height: 1.3,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
