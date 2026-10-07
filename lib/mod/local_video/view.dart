import 'dart:io';

import 'package:PiliPlus/mod/local_video/controller.dart';
import 'package:PiliPlus/utils/extension/get_ext.dart';
import 'package:PiliPlus/utils/feed_back.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:get/get.dart';
import 'package:material_ui/material_ui.dart';

/// 「本地」tab：挑本地视频文件并播放。
///
/// 播放走官方视频页的 `SourceType.file` 分支（见 lib/mod/local_video/controller.dart）。
class LocalVideoPage extends StatefulWidget {
  const LocalVideoPage({super.key});

  @override
  State<LocalVideoPage> createState() => _LocalVideoPageState();
}

class _LocalVideoPageState extends State<LocalVideoPage>
    with AutomaticKeepAliveClientMixin {
  final _controller = Get.putOrFind(LocalVideoController.new);

  @override
  bool get wantKeepAlive => true;

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: const Text('本地视频'),
        actions: [
          IconButton(
            tooltip: '添加视频',
            onPressed: _pick,
            icon: const Icon(Icons.add),
          ),
          Obx(
            () => _controller.list.isEmpty
                ? const SizedBox.shrink()
                : IconButton(
                    tooltip: '清空列表',
                    onPressed: () async {
                      await _controller.clear();
                      SmartDialog.showToast('已清空（不会删除文件）');
                    },
                    icon: const Icon(Icons.delete_sweep_outlined),
                  ),
          ),
        ],
      ),
      body: Obx(() {
        final list = _controller.list;
        if (list.isEmpty) {
          return _empty(theme);
        }
        return ListView.separated(
          padding: const EdgeInsets.only(bottom: 100),
          itemCount: list.length,
          separatorBuilder: (_, _) => const Divider(height: 1, indent: 16),
          itemBuilder: (context, index) {
            final item = list[index];
            return ListTile(
              leading: const Icon(Icons.movie_outlined),
              title: Text(
                item.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              subtitle: Text(
                '${item.path}\n${_size(item.path)}',
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 11,
                  color: theme.colorScheme.outline,
                ),
              ),
              isThreeLine: true,
              onTap: () {
                feedBack();
                _controller.play(item);
              },
              trailing: IconButton(
                tooltip: '从列表移除（不会删除文件）',
                onPressed: () => _controller.remove(item),
                icon: const Icon(Icons.close),
              ),
            );
          },
        );
      }),
    );
  }

  Future<void> _pick() async {
    final res = await _controller.pick();
    final msg = res.message;
    if (msg.isNotEmpty) SmartDialog.showToast(msg);
  }

  Widget _empty(ThemeData theme) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.video_library_outlined,
            size: 64,
            color: theme.colorScheme.outline,
          ),
          const SizedBox(height: 16),
          Text(
            '还没有本地视频',
            style: TextStyle(color: theme.colorScheme.outline),
          ),
          const SizedBox(height: 8),
          const Text(
            '添加后可以直接在这里播放，进度会像在线视频一样记住',
            style: TextStyle(fontSize: 12),
          ),
          const SizedBox(height: 20),
          FilledButton.icon(
            onPressed: _pick,
            icon: const Icon(Icons.add),
            label: const Text('添加视频'),
          ),
        ],
      ),
    );
  }

  static String _size(String path) {
    try {
      final bytes = File(path).lengthSync();
      if (bytes >= 1 << 30) {
        return '${(bytes / (1 << 30)).toStringAsFixed(2)} GB';
      }
      if (bytes >= 1 << 20) {
        return '${(bytes / (1 << 20)).toStringAsFixed(1)} MB';
      }
      return '${(bytes / 1024).toStringAsFixed(0)} KB';
    } catch (_) {
      return '';
    }
  }
}
