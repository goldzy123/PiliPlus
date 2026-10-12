import 'package:PiliPlus/common/widgets/route_aware_mixin.dart';
import 'package:PiliPlus/mod/local_video/controller.dart';
import 'package:PiliPlus/utils/extension/get_ext.dart';
import 'package:PiliPlus/utils/feed_back.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:get/get.dart';
import 'package:material_ui/material_ui.dart';

/// 「本地」tab：把本地视频当成一个完整的播放列表来管理。
///
/// · 常用目录：整个文件夹纳入管理，自动递归扫描里面的视频（扫描时保留原路径，
///   不搬文件，免得用户在自己的目录里找不到）；
/// · 手动添加：走系统文件选择器选单个/多个文件；
/// · 观看进度：复用官方那套（cid = 文件路径的稳定哈希），列表里显示"上次看到"，
///   再点进去自动续播；
/// · 搜索 / 排序 / 按目录分组 / 单条移除 / 清空。
///
/// 播放走官方视频页的 `SourceType.file` 分支（见 controller.dart）。
class LocalVideoPage extends StatefulWidget {
  const LocalVideoPage({super.key});

  @override
  State<LocalVideoPage> createState() => _LocalVideoPageState();
}

class _LocalVideoPageState extends State<LocalVideoPage>
    with AutomaticKeepAliveClientMixin, RouteAware, RouteAwareMixin {
  final _controller = Get.putOrFind(LocalVideoController.new);
  final _searchCtrl = TextEditingController();
  bool _searching = false;

  @override
  bool get wantKeepAlive => true;

  /// 从播放页返回时刷新列表：观看进度是在播放页里写的，
  /// 不刷新的话列表还显示旧值（踩过）。
  @override
  void didPopNext() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  void _toast(String msg) {
    if (msg.isNotEmpty) SmartDialog.showToast(msg);
  }

  Future<void> _pickFiles() async {
    final res = await _controller.pick();
    _toast(res.message);
  }

  Future<void> _pickFolder() async {
    final n = await _controller.pickFolder();
    if (n == null) {
      _toast('没选目录，或没拿到「所有文件访问」权限');
    } else {
      _toast(n > 0 ? '已扫描到 $n 个视频' : '这个目录里没有新视频');
    }
  }

  Future<void> _scanAll() async {
    if (_controller.folders.isEmpty) {
      _toast('还没有常用目录，先「添加常用目录」');
      return;
    }
    final n = await _controller.scanAllFolders();
    _toast(n > 0 ? '新增 $n 个视频' : '没有新视频');
  }

  Future<void> _removeFolder(LocalFolder f) async {
    // 返回 true=保留视频；false/null=连视频一起从列表移除
    final keep = await SmartDialog.show<bool>(
      builder: (_) => AlertDialog(
        title: Text('移除常用目录「${f.name}」？'),
        content: const Text('不会删除任何文件。'),
        actions: [
          TextButton(
            onPressed: () => SmartDialog.dismiss(result: false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => SmartDialog.dismiss(result: true),
            child: const Text('保留已扫描的视频'),
          ),
          TextButton(
            onPressed: () => SmartDialog.dismiss(result: null),
            child: const Text('连视频一起移除'),
          ),
        ],
      ),
    );
    if (keep == false) return; // 取消
    await _controller.removeFolder(f, removeVideos: keep != true);
    _toast('已移除目录');
  }

  Future<void> _clearAll() async {
    final ok = await SmartDialog.show<bool>(
      builder: (_) => AlertDialog(
        title: const Text('清空本地视频列表？'),
        content: const Text('只清列表，不会删除任何文件。'),
        actions: [
          TextButton(
            onPressed: () => SmartDialog.dismiss(result: false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => SmartDialog.dismiss(result: true),
            child: const Text('清空'),
          ),
        ],
      ),
    );
    if (ok == true) {
      await _controller.clear();
      _toast('已清空');
    }
  }

  void _itemMenu(LocalVideoItem item) {
    final progress = _controller.progressOf(item);
    SmartDialog.show(
      builder: (_) => AlertDialog(
        title: Text(
          item.name,
          style: const TextStyle(fontSize: 15),
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(progress > 0 ? '上次看到 ${LocalVideoStore.fmt(progress)}' : '还没有观看记录'),
            if (item.size > 0) ...[
              const SizedBox(height: 4),
              Text(
                LocalVideoStore.fmtSize(item.size),
                style: const TextStyle(fontSize: 12, color: Colors.grey),
              ),
            ],
          ],
        ),
        actions: [
          if (progress > 0)
            TextButton(
              onPressed: () async {
                await LocalVideoStore.clearProgressOf(item.path);
                SmartDialog.dismiss();
                setState(() {});
                _toast('已清除观看进度');
              },
              child: const Text('清除进度'),
            ),
          TextButton(
            onPressed: () async {
              SmartDialog.dismiss();
              await _controller.remove(item);
              _toast('已从列表移除（文件没删）');
            },
            child: const Text('移除'),
          ),
          TextButton(
            onPressed: () {
              SmartDialog.dismiss();
              feedBack();
              _controller.play(item);
            },
            child: const Text('播放'),
          ),
        ],
      ),
    );
  }

  Widget _itemTile(LocalVideoItem item) {
    final progress = _controller.progressOf(item);
    final sub = <String>[
      if (item.size > 0) LocalVideoStore.fmtSize(item.size),
      if (progress > 0) '上次看到 ${LocalVideoStore.fmt(progress)}',
    ].join(' · ');
    return ListTile(
      dense: true,
      contentPadding: const EdgeInsets.only(left: 12, right: 0),
      leading: const Icon(Icons.movie_outlined),
      title: Text(
        item.name,
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(fontSize: 14),
      ),
      subtitle: sub.isEmpty
          ? null
          : Text(sub, style: const TextStyle(fontSize: 11)),
      trailing: IconButton(
        icon: const Icon(Icons.more_vert),
        onPressed: () => _itemMenu(item),
      ),
      onTap: () {
        feedBack();
        _controller.play(item);
      },
      onLongPress: () => _itemMenu(item),
    );
  }

  Widget _groupHeader(String title, LocalFolder? folder, int count) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 10, 0, 0),
      child: Row(
        children: [
          Icon(
            folder == null ? Icons.playlist_add : Icons.folder_outlined,
            size: 18,
            color: Theme.of(context).colorScheme.primary,
          ),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              '$title  ($count)',
              style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 14),
            ),
          ),
          if (folder != null)
            IconButton(
              tooltip: '扫描这个目录',
              icon: const Icon(Icons.refresh, size: 18),
              onPressed: () async {
                final n = await _controller.scanFolder(folder);
                _toast(n > 0 ? '新增 $n 个视频' : '没有新视频');
              },
            ),
          if (folder != null)
            IconButton(
              tooltip: '移除这个目录',
              icon: const Icon(Icons.folder_delete_outlined, size: 18),
              onPressed: () => _removeFolder(folder),
            ),
        ],
      ),
    );
  }

  Widget _empty() {
    final theme = Theme.of(context);
    return Center(
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.video_library_outlined,
              size: 64,
              color: theme.colorScheme.outline,
            ),
            const SizedBox(height: 16),
            Text('还没有本地视频', style: TextStyle(color: theme.colorScheme.outline)),
            const SizedBox(height: 8),
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 40),
              child: Text(
                '「添加常用目录」可以把整个文件夹纳入管理，会自动扫描里面的视频；'
                '也可以直接选几个文件。进度会像在线视频一样记住。',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 12),
              ),
            ),
            const SizedBox(height: 20),
            FilledButton.icon(
              onPressed: _pickFolder,
              icon: const Icon(Icons.create_new_folder_outlined),
              label: const Text('添加常用目录'),
            ),
            const SizedBox(height: 10),
            OutlinedButton.icon(
              onPressed: _pickFiles,
              icon: const Icon(Icons.add),
              label: const Text('添加视频文件'),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return Scaffold(
      appBar: AppBar(
        title: _searching
            ? TextField(
                controller: _searchCtrl,
                autofocus: true,
                decoration: const InputDecoration(
                  hintText: '搜索文件名',
                  border: InputBorder.none,
                ),
                onChanged: (v) => _controller.keyword.value = v,
              )
            : const Text('本地视频'),
        actions: [
          IconButton(
            tooltip: _searching ? '退出搜索' : '搜索',
            icon: Icon(_searching ? Icons.close : Icons.search),
            onPressed: () {
              setState(() {
                _searching = !_searching;
                if (!_searching) {
                  _searchCtrl.clear();
                  _controller.keyword.value = '';
                }
              });
            },
          ),
          Obx(() {
            // 读这两个 Rx，排序/数量变化时才会重建
            final sort = _controller.sort.value;
            final count = _controller.list.length;
            return PopupMenuButton<LocalVideoSort>(
              tooltip: '排序（当前：${sort.label}，共 $count 个）',
              icon: const Icon(Icons.sort),
              initialValue: sort,
              onSelected: (v) => _controller.sort.value = v,
              itemBuilder: (_) => [
                for (final s in LocalVideoSort.values)
                  PopupMenuItem(value: s, child: Text(s.label)),
              ],
            );
          }),
          PopupMenuButton<String>(
            onSelected: (v) async {
              switch (v) {
                case 'folder':
                  await _pickFolder();
                case 'files':
                  await _pickFiles();
                case 'scan':
                  await _scanAll();
                case 'clear':
                  await _clearAll();
              }
            },
            itemBuilder: (_) => const [
              PopupMenuItem(value: 'folder', child: Text('添加常用目录')),
              PopupMenuItem(value: 'files', child: Text('添加视频文件')),
              PopupMenuItem(value: 'scan', child: Text('重新扫描全部目录')),
              PopupMenuItem(value: 'clear', child: Text('清空列表')),
            ],
          ),
        ],
      ),
      body: Obx(() {
        if (_controller.scanning.value) {
          return const Center(child: CircularProgressIndicator());
        }
        if (_controller.list.isEmpty) return _empty();
        final groups = _controller.grouped;
        if (groups.isEmpty) {
          return const Center(child: Text('没有匹配的视频'));
        }
        final entries = groups.entries.toList();
        // 把分组摊平成一个列表，省掉一层依赖
        final rows = <Widget>[];
        for (final e in entries) {
          final folder = _controller.folders
              .where((f) => f.name == e.key)
              .firstOrNull;
          rows
            ..add(_groupHeader(e.key, folder, e.value.length))
            ..addAll(e.value.map(_itemTile));
        }
        return ListView.builder(
          padding: const EdgeInsets.only(bottom: 100),
          itemCount: rows.length,
          itemBuilder: (_, i) => rows[i],
        );
      }),
    );
  }
}
