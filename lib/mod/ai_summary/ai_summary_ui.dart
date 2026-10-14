import 'package:PiliPlus/mod/ai_summary/summary_service.dart';
import 'package:PiliPlus/pages/video/controller.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:material_ui/material_ui.dart';

/// 「AI 总结」在官方没货时的兜底 UI。
///
/// 原来的行为是直接弹一句「当前视频不支持AI视频总结」就完了 —— 实际上
/// 只要视频有字幕（自带或官方 AI 字幕），总结完全可以自己生成。
/// 这里把那条路接上：先看本地缓存，再让局域网里的 Mac 生成，然后显示出来。
abstract final class ModAiSummary {
  /// 官方结论拿不到时调用。返回 true 表示「已经接管」（显示了内容或给出了提示）。
  ///
  /// [ctr] 是对应的 VideoDetailController，用来拿播放信息里的字幕。
  static Future<bool> fallback({
    required BuildContext context,
    required VideoDetailController ctr,
  }) async {
    final bvid = ctr.bvid;
    final cid = '${ctr.cid.value}';

    // 1) 手机缓存 —— 之前生成过就直接给
    final hit = ModSummaryService.cached(bvid, cid);
    if (hit != null && hit.summary.isNotEmpty) {
      if (context.mounted) _show(context, hit);
      return true;
    }

    if (!ModSummaryService.configured) {
      // 没配地址就老老实实说清楚，别让人以为是 app 坏了
      SmartDialog.showToast(
        'B 站没有这个视频的现成总结\n要本地生成，请在设置里填「总结服务地址」',
      );
      return true;
    }

    SmartDialog.showToast('B 站没有现成总结，正在本地生成…首次可能要等一会儿');
    final res = await ModSummaryService.generateFor(
      bvid: bvid,
      cid: cid,
      data: ctr.data,
      title: ctr.videoDetail.value.title ?? '',
      upName: ctr.currentUpName ?? '',
    );

    if (res == null) {
      SmartDialog.showToast('连不上总结服务：${ModSummaryService.baseUrl}');
      return true;
    }
    if (res.failed || res.summary.isEmpty) {
      SmartDialog.showToast(res.sourceLabel);
      return true;
    }
    if (context.mounted) _show(context, res);
    return true;
  }

  static void _show(BuildContext context, ModSummaryResult r) {
    final theme = Theme.of(context);
    showDialog(
      context: context,
      builder: (context) => Dialog(
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 14),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Row(
                  children: [
                    const Icon(Icons.auto_awesome, size: 18),
                    const SizedBox(width: 6),
                    const Text(
                      '本地生成总结',
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const Spacer(),
                    Text(
                      r.sourceLabel,
                      style: TextStyle(
                        fontSize: 11,
                        color: theme.colorScheme.outline,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 8),
              Flexible(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: SelectionArea(
                    child: Text(
                      r.summary,
                      style: const TextStyle(fontSize: 14, height: 1.6),
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 6),
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('关闭'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
