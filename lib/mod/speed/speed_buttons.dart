import 'package:PiliPlus/mod/speed/playback_speed_service.dart';
import 'package:PiliPlus/plugin/pl_player/controller.dart';
import 'package:PiliPlus/utils/feed_back.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:get/get.dart';
import 'package:material_ui/material_ui.dart';

/// 倍速按钮放在哪儿。
enum ModSpeedPlacement {
  /// 播放器控制条那一行（全屏 / 横屏）
  playerRow,

  /// 视频详情页 UP 名与关注按钮之间（竖屏）
  upRow,
}

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
/// 位置：竖屏放 UP 那一行；全屏/横屏并入播放器控制条同一行（不再单独占行）。
/// 注意判断依据是**全屏状态 + 屏幕方向**，不能用播放器里的 `isLandscape`
/// —— 那个是"视频本身是横的"，竖屏看横版视频时会误判，导致两处都出现。
class ModSpeedButtons extends StatelessWidget {
  const ModSpeedButtons({
    super.key,
    required this.controller,
    required this.placement,
    this.upMid,
    this.upName,
  });

  final PlPlayerController controller;
  final ModSpeedPlacement placement;
  final int? upMid;
  final String? upName;

  bool get _compact => placement == ModSpeedPlacement.playerRow;

  @override
  Widget build(BuildContext context) {
    // 只看全屏状态：全屏 → 控制条那一行；非全屏 → UP 名与关注按钮之间。
    // 不要掺屏幕方向或播放器的 isLandscape：横屏非全屏时播放器和 UP 行同时存在，
    // 按方向判断会两处都出现；isLandscape 还是"视频本身是横的"，更容易误判。
    return Obx(() {
      final full = controller.isFullScreen.value;
      final show = switch (placement) {
        ModSpeedPlacement.playerRow => full,
        ModSpeedPlacement.upRow => !full,
      };
      if (!show) return const SizedBox.shrink();

      final forced = upMid == null
          ? null
          : PlaybackSpeedService.upSpeed(upMid!);
      return Padding(
        padding: EdgeInsets.only(
          right: _compact ? 8 : 6,
          top: _compact ? 0 : 2,
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            _pill(context, 0, forced),
            SizedBox(width: _compact ? 6 : 8),
            _pill(context, 1, forced),
          ],
        ),
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
      // 播放器控制条压在视频画面上，普通态要用白色系才看得清
      bg = Colors.transparent;
      fg = _compact ? Colors.white.withValues(alpha: 0.9) : scheme.outline;
      border = _compact
          ? Colors.white.withValues(alpha: 0.65)
          : scheme.outline.withValues(alpha: 0.55);
      icon = null;
    }

    final text = Text(
      '${_fmt(speed)}X',
      style: TextStyle(fontSize: _compact ? 11 : 12, color: fg),
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
          height: _compact ? 22 : 26,
          padding: EdgeInsets.symmetric(horizontal: _compact ? 7 : 9),
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
                Icon(icon, size: _compact ? 11 : 12, color: fg),
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
  /// 播放器控制条同一行里的倍速按钮（全屏才显示）。
  static Widget playerRowItems({
    required PlPlayerController controller,
    int? upMid,
    String? upName,
  }) {
    return ModSpeedButtons(
      controller: controller,
      placement: ModSpeedPlacement.playerRow,
      upMid: upMid,
      upName: upName,
    );
  }

  /// 视频详情页 UP 名与关注按钮之间的倍速按钮（非全屏才显示）。
  static Widget upRowItems({
    required PlPlayerController controller,
    int? upMid,
    String? upName,
  }) {
    return ModSpeedButtons(
      controller: controller,
      placement: ModSpeedPlacement.upRow,
      upMid: upMid,
      upName: upName,
    );
  }
}
