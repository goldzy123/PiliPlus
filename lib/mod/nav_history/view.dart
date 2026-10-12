import 'package:PiliPlus/mod/nav_history/nav_history.dart';
import 'package:PiliPlus/utils/extension/get_ext.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:get/get.dart';
import 'package:material_ui/material_ui.dart';

/// 浏览历史树页面。
///
/// 左边缩进表示层级，同一层有多个就是「分叉」。
/// 点任意一条可以：跳到这里 / 从这里重新开始 / 回首页。
class NavHistoryPage extends StatefulWidget {
  const NavHistoryPage({super.key});

  @override
  State<NavHistoryPage> createState() => _NavHistoryPageState();
}

class _NavHistoryPageState extends State<NavHistoryPage> {
  final _svc = Get.putOrFind(NavHistoryService.new);

  /// 深度优先展开成列表，同时带上缩进层级
  List<(NavNode, int, bool)> _flatten() {
    final out = <(NavNode, int, bool)>[];
    final roots =
        _svc.nodes.values.where((n) => n.parentId == null).toList()
          ..sort((a, b) => a.id.compareTo(b.id));
    void walk(NavNode n, int depth, bool isLast) {
      out.add((n, depth, isLast));
      final kids = n.children
          .map((id) => _svc.nodes[id])
          .whereType<NavNode>()
          .toList()
        ..sort((a, b) => a.id.compareTo(b.id));
      for (var i = 0; i < kids.length; i++) {
        walk(kids[i], depth + 1, i == kids.length - 1);
      }
    }

    for (var i = 0; i < roots.length; i++) {
      walk(roots[i], 0, i == roots.length - 1);
    }
    return out;
  }

  String _time(int ms) {
    final d = DateTime.fromMillisecondsSinceEpoch(ms);
    return '${d.hour.toString().padLeft(2, '0')}:'
        '${d.minute.toString().padLeft(2, '0')}:'
        '${d.second.toString().padLeft(2, '0')}';
  }

  Future<void> _jump(NavNode n, {bool branch = false}) async {
    SmartDialog.dismiss();
    final ok = await _svc.jumpTo(n.id);
    if (!ok) {
      SmartDialog.showToast('这个位置已经跳不过去了（参数只在当次运行里有效）');
      return;
    }
    // 跳转是逐个 pop/push，等它走完再退出本页，免得自己被一起退掉
    await Future<void>.delayed(const Duration(milliseconds: 400));
    if (mounted) Get.back();
    SmartDialog.showToast(branch ? '已回到这里，继续浏览会长出新分支' : '已跳到这里');
  }

  void _menu(NavNode n, int depth) {
    SmartDialog.show(
      builder: (_) => AlertDialog(
        title: Text(
          n.title,
          style: const TextStyle(fontSize: 15),
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('路由：${n.route}'),
            Text('时间：${_time(n.at)}'),
            Text('层级：第 ${depth + 1} 层，下面有 ${n.children.length} 个分叉'),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => _jump(n, branch: true),
            child: const Text('从这里重新开始'),
          ),
          TextButton(
            onPressed: () => _jump(n),
            child: const Text('跳到这里'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: const Text('浏览历史'),
        actions: [
          IconButton(
            tooltip: '回首页',
            icon: const Icon(Icons.home_outlined),
            onPressed: () async {
              await _svc.goHome();
              await Future<void>.delayed(const Duration(milliseconds: 400));
              if (mounted) Get.back();
            },
          ),
          IconButton(
            tooltip: '清空历史',
            icon: const Icon(Icons.delete_sweep_outlined),
            onPressed: () {
              _svc.clear();
              SmartDialog.showToast('已清空浏览历史');
            },
          ),
        ],
      ),
      body: Obx(() {
        final _ = _svc.version.value; // 订阅变化
        final rows = _flatten();
        if (rows.isEmpty) {
          return const Center(child: Text('还没有浏览记录'));
        }
        final currentId = _svc.currentId;
        return ListView.builder(
          padding: const EdgeInsets.only(bottom: 80),
          itemCount: rows.length,
          itemBuilder: (_, i) {
            final (n, depth, isLast) = rows[i];
            final isCurrent = n.id == currentId;
            final isOnStack = _svc.stack.contains(n.id);
            return InkWell(
              onTap: () => _menu(n, depth),
              child: Padding(
                padding: EdgeInsets.only(left: 12 + depth * 18.0, right: 8),
                child: Row(
                  children: [
                    // 树形引导线
                    if (depth > 0)
                      Padding(
                        padding: const EdgeInsets.only(right: 6),
                        child: Text(
                          isLast ? '└' : '├',
                          style: TextStyle(color: theme.colorScheme.outline),
                        ),
                      ),
                    Icon(
                      isCurrent
                          ? Icons.my_location
                          : isOnStack
                          ? Icons.circle
                          : Icons.circle_outlined,
                      size: isCurrent ? 16 : 10,
                      color: isCurrent
                          ? theme.colorScheme.primary
                          : theme.colorScheme.outline,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            n.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 14,
                              fontWeight: isCurrent
                                  ? FontWeight.w600
                                  : FontWeight.normal,
                            ),
                          ),
                          Text(
                            '${n.route} · ${_time(n.at)}'
                            '${n.visits > 1 ? ' · 来过 ${n.visits} 次' : ''}',
                            style: TextStyle(
                              fontSize: 11,
                              color: theme.colorScheme.outline,
                            ),
                          ),
                        ],
                      ),
                    ),
                    if (isCurrent)
                      Padding(
                        padding: const EdgeInsets.only(left: 6),
                        child: Text(
                          '当前',
                          style: TextStyle(
                            fontSize: 11,
                            color: theme.colorScheme.primary,
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            );
          },
        );
      }),
    );
  }
}
