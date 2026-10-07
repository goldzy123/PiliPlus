import 'package:PiliPlus/mod/speed/playback_speed_service.dart';
import 'package:PiliPlus/plugin/pl_player/controller.dart';
import 'package:PiliPlus/utils/feed_back.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:get/get.dart';
import 'package:material_ui/material_ui.dart';

/// 快捷倍速按钮（mod）。
///
/// 两个按钮，点按 = 把当前视频切到该倍速；长按 = 把该倍速设成当前 UP 的
/// **强制倍速**（再次长按同一项则取消）。
///
/// 三种状态用「形状 + 颜色 + 图标」区分：
/// | 状态 | 形状 | 颜色 | 图标 |
/// | --- | --- | --- | --- |
/// | 该 UP 的强制倍速 | 实心圆角矩形 | 主题色填充 | 人形 |
/// | 当前正在使用的倍速 | 胶囊描边 | 主题色描边 | 对勾 |
/// | 普通 | 胶囊描边 | 弱化描边 | 无 |
///
/// 竖屏时放在视频详情页 UP 主名字与关注按钮之间；全屏/横屏时并入播放器
/// 控制条同一行（不再单独占一行）。
class ModSpeedButtons extends StatelessWidget {
  const ModSpeedButtons({
    super.key,
    required this.controller,
    this.upMid,
    this.upName,
    this.compact = false,
  });

  final PlPlayerController controller;
  final int? upMid;
  final String? upName;

  /// 紧凑模式：用在播放器控制条里，尺寸更小。
  final bool compact;

  @override
  Widget build(BuildContext context) {
    return Obx(() {
      final forced = upMid == null
          ? null
          : PlaybackSpeedService.upSpeed(upMid!);
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _pill(context, 0, forced),
          SizedBox(width: compact ? 6 : 8),
          _pill(context, 1, forced),
        ],
      );
    });
  }

  Widget _pill(BuildContext context, int index, double? forced) {
    final scheme = ColorScheme.of(context);
    final speed = index == 0
        ? controller.quickSpeed1.value
        : controller.quickSpeed2.value;
    final isUpForced = forced != null && forced == speed;
    final isCurrent = !isUpForced && controller.playbackSpeed == speed;

    final Color bg;
    final Color fg;
    final Color border;
    final IconData? icon;
    if (isUpForced) {
      bg = scheme.primary;
      fg = scheme.onPrimary;
      border = scheme.primary;
      icon = Icons.person;
    } else if (isCurrent) {
      bg = Colors.transparent;
      fg = scheme.primary;
      border = scheme.primary;
      icon = Icons.check;
    } else {
      bg = Colors.transparent;
      fg = scheme.outline;
      border = scheme.outline.withValues(alpha: 0.55);
      icon = null;
    }

    final text = Text(
      '${_fmt(speed)}X',
      style: TextStyle(fontSize: compact ? 11 : 12, color: fg),
    );

    return Tooltip(
      message: isUpForced
          ? '该 UP 强制倍速 ${_fmt(speed)}X\n长按取消'
          : '${_fmt(speed)}X\n点按切换 · 长按设为该 UP 强制倍速',
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () {
          feedBack();
          controller.toggleQuickSpeed(index);
        },
        onLongPress: () => _onLongPress(index, speed, forced),
        child: Container(
          height: compact ? 22 : 26,
          padding: EdgeInsets.symmetric(horizontal: compact ? 7 : 9),
          decoration: BoxDecoration(
            color: bg,
            border: Border.all(color: border, width: isUpForced ? 0 : 1),
            // 形状区分：UP 强制用圆角矩形，其余用胶囊
            borderRadius: BorderRadius.circular(isUpForced ? 6 : 14),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (icon != null) ...[
                Icon(icon, size: compact ? 11 : 12, color: fg),
                const SizedBox(width: 3),
              ],
              text,
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _onLongPress(int index, double speed, double? forced) async {
    feedBack();
    final mid = upMid;
    if (mid == null) {
      SmartDialog.showToast('当前视频没有 UP 主');
      return;
    }
    if (forced == speed) {
      await PlaybackSpeedService.removeUpSpeed(mid);
      SmartDialog.showToast('已取消该 UP 的强制倍速');
      return;
    }
    await PlaybackSpeedService.setUpSpeed(mid: mid, speed: speed, name: upName);
    await controller.setPlaybackSpeed(speed);
    SmartDialog.showToast('已将该 UP 强制为 ${_fmt(speed)}X');
  }

  static String _fmt(double v) =>
      v == v.roundToDouble() ? v.toStringAsFixed(0) : v.toString();
}

/// 对官方文件的 hook 封装，见 `lib/mod/README.md`。
abstract final class ModSpeedHooks {
  /// 播放器控制条同一行内的倍速按钮。
  /// 只在全屏或横屏时返回内容——竖屏时按钮在 UP 主那一行。
  static List<Widget> playerRowItems({
    required PlPlayerController controller,
    required bool isFullScreen,
    required bool isLandscape,
    int? upMid,
    String? upName,
  }) {
    if (!isFullScreen && !isLandscape) return const [];
    return [
      ModSpeedButtons(
        controller: controller,
        upMid: upMid,
        upName: upName,
        compact: true,
      ),
      const SizedBox(width: 8),
    ];
  }

  /// 视频详情页 UP 主名字与关注按钮之间的倍速按钮。
  static List<Widget> upRowItems({
    required PlPlayerController controller,
    required bool isLandscape,
    int? upMid,
    String? upName,
  }) {
    if (isLandscape) return const [];
    return [
      ModSpeedButtons(
        controller: controller,
        upMid: upMid,
        upName: upName,
      ),
      const SizedBox(width: 6),
    ];
  }
}
