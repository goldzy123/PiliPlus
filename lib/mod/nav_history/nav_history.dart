import 'dart:async';

import 'package:PiliPlus/models/common/nav_bar_config.dart';
import 'package:PiliPlus/pages/main/controller.dart';
import 'package:PiliPlus/utils/extension/get_ext.dart';
import 'package:flutter/widgets.dart';
import 'package:get/get.dart';

/// 一个浏览节点（= 一次页面停留）。
class NavNode {
  NavNode({
    required this.id,
    required this.route,
    required this.title,
    required this.at,
    this.parentId,
    this.args,
  });

  final int id;

  /// 上一个页面（根为 null）。这就是「分叉」的由来：
  /// 同一个父节点下可以有多个子节点。
  final int? parentId;

  final String route;
  final String title;
  final int at;

  /// 访问次数（同一节点被重用时累加）
  int visits = 1;

  /// 页面参数。**只存在内存里**：PiliPlus 的参数 Map 里常有模型对象
  /// （比如 `pgcItem`），没法序列化。所以跳转只在本会话内保证可用，
  /// 重启后历史还在但跳不过去。
  Map<String, dynamic>? args;

  final List<int> children = <int>[];
}

/// 路由名 → 给人看的标签（没收录的用路由名本身）
const _routeLabels = <String, String>{
  '/': '首页',
  '/home': '首页',
  '/hot': '热门',
  '/videoV': '视频',
  '/search': '搜索',
  '/searchResult': '搜索结果',
  '/member': 'UP 主页',
  '/fav': '收藏',
  '/favDetail': '收藏夹',
  '/later': '稍后再看',
  '/history': '历史记录',
  '/dynamics': '动态',
  '/dynamicDetail': '动态详情',
  '/liveRoom': '直播间',
  '/articlePage': '专栏',
  '/setting': '设置',
  '/webview': '网页',
  '/follow': '关注',
  '/fan': '粉丝',
  '/navHistory': '浏览历史',
  '/settingsSync': '配置同步',
  '/settingFavorites': '设置收藏',
  '/playSpeedSet': '倍速设置',
  '/speedAutoSet': '智能倍速',
  '/localVideo': '本地视频',
  '/displayModeSetting': '显示模式',
  '/colorSetting': '主题色',
  '/fontSetting': '字体设置',
  '/whisper': '悄悄关注',
  '/blackListPage': '黑名单',
  '/favSearch': '收藏搜索',
  '/memberSearch': '用户搜索',
  '/download': '下载管理',
};

String _labelOf(String route) =>
    _routeLabels[route] ?? (route.isEmpty ? '页面' : route);

/// 浏览历史树。
///
/// 官方的后退是个**线性的栈**：回退一次，原来那条路的后面就没了。
/// 这里把它记成一棵**树** —— 回退之后再点别的东西会在同一个父节点下
/// 长出新分支，每条分叉都留着。于是可以：
///   · 一次跳回很早之前的某个位置；
///   · 直接回首页；
///   · 从中间某个节点重新开始（在它下面继续长新分支）。
///
/// 跳转的实现是「共同祖先 + 只补推差集」，而不是从头重放整条链 ——
/// 重放会把中间每个页面都重新加载一遍，又慢又有副作用。
class NavHistoryService extends GetxController {
  static NavHistoryService get to => Get.putOrFind(NavHistoryService.new);

  /// 所有节点，按 id 索引
  final nodes = <int, NavNode>{};

  /// 变化计数：树是普通 Map，用它触发 UI 重建
  final version = 0.obs;

  /// 当前导航栈的节点 id（根在前）
  final stack = <int>[].obs;

  int _seq = 0;

  /// route → 节点 id（用 route 对象本身当键，等价于身份比较）
  final _routeNode = <Route, int>{};
  final _routeOrder = <Route>[];

  /// 跳转补推时指定「这次 push 对应哪个已存在的节点」，避免跳一次就多长一个重复节点
  int? _pendingNode;

  int get currentId => stack.isEmpty ? -1 : stack.last;

  // ── 观察器回调 ────────────────────────────────────────────────

  void onPush(Route route) {
    final name = route.settings.name ?? '';
    if (name.isEmpty) return;
    final args = route.settings.arguments;
    final argMap = args is Map ? Map<String, dynamic>.from(args) : null;
    final parentId = stack.isEmpty ? null : stack.last;

    final reuse = _pendingNode;
    _pendingNode = null;
    if (reuse != null && nodes.containsKey(reuse)) {
      // 跳转补推：复用已有节点，只更新栈
      final n = nodes[reuse]!;
      n.visits++;
      n.args = argMap ?? n.args;
      _routeNode[route] = reuse;
      _routeOrder.add(route);
      _refreshStack();
      version.value++;
      return;
    }

    final title = _titleFrom(argMap, name);

    // [MOD-HOOK:nav-history-dedup] 同一个位置重复进？
    // 从同一个父节点反复打开同一个视频（比如来回切两个视频看），
    // 原来每次都长一个新节点，树很快就被同一个标题刷屏、看不出"分叉"。
    // 这里改成：父节点下已有同名同路由的子节点就复用，只加访问次数。
    // 注意只跟**同一个父节点下的兄弟**比 —— 不同层级的同名页面是真·不同位置，
    // 合并了反而会丢掉分叉结构。
    if (parentId != null) {
      final siblings = nodes[parentId]?.children;
      if (siblings != null) {
        for (final childId in siblings) {
          final c = nodes[childId];
          if (c != null && c.route == name && c.title == title) {
            c.visits++;
            c.args = argMap ?? c.args;
            _routeNode[route] = childId;
            _routeOrder.add(route);
            _refreshStack();
            version.value++;
            return;
          }
        }
      }
    }

    final node = NavNode(
      id: ++_seq,
      parentId: parentId,
      route: name,
      title: title,
      at: DateTime.now().millisecondsSinceEpoch,
      args: argMap,
    );
    nodes[node.id] = node;
    if (parentId != null) {
      nodes[parentId]?.children.add(node.id);
    }
    _routeNode[route] = node.id;
    _routeOrder.add(route);
    _refreshStack();
    version.value++;
  }

  void onPop(Route route) {
    if (!_routeNode.containsKey(route)) return;
    _routeNode.remove(route);
    _routeOrder.remove(route);
    _refreshStack();
    version.value++;
  }

  void onRemove(Route route) {
    if (!_routeNode.containsKey(route)) return;
    _routeNode.remove(route);
    _routeOrder.remove(route);
    _refreshStack();
    version.value++;
  }

  void onReplace(Route? oldRoute, Route? newRoute) {
    if (oldRoute != null && _routeNode.containsKey(oldRoute)) {
      final id = _routeNode.remove(oldRoute)!;
      _routeOrder.remove(oldRoute);
      if (newRoute != null) {
        _routeNode[newRoute] = id;
        _routeOrder.add(newRoute);
      }
    } else if (newRoute != null) {
      onPush(newRoute);
      return;
    }
    _refreshStack();
    version.value++;
  }

  String _titleFrom(Map<String, dynamic>? args, String route) {
    final t = args?['title'] ?? args?['name'];
    if (t is String && t.trim().isNotEmpty) return t.trim();
    return _labelOf(route);
  }

  void _refreshStack() {
    stack.assignAll([
      for (final r in _routeOrder) ?_routeNode[r],
    ]);
  }

  // ── 树操作 ────────────────────────────────────────────────────

  /// 从根到该节点的路径（含自身）
  List<int> pathOf(int id) {
    final out = <int>[];
    int? cur = id;
    var guard = 0;
    while (cur != null && nodes.containsKey(cur) && guard++ < 500) {
      out.insert(0, cur);
      cur = nodes[cur]!.parentId;
    }
    return out;
  }

  /// 根节点（可能有多个，取第一个）
  int? get rootId =>
      nodes.values.where((n) => n.parentId == null).firstOrNull?.id;

  /// 深度（用于缩进）
  int depthOf(int id) => pathOf(id).length - 1;

  /// 跳到一个节点。
  ///
  /// 目标在当前栈里 → 只往回退；
  /// 目标在别的分支 → 退到共同祖先，再把差集补推上去。
  Future<bool> jumpTo(int id) async {
    if (!nodes.containsKey(id)) return false;
    final target = pathOf(id);
    final current = stack.toList();

    var common = 0;
    while (common < target.length &&
        common < current.length &&
        target[common] == current[common]) {
      common++;
    }

    // 先退到共同祖先
    final toPop = current.length - common;
    for (var i = 0; i < toPop; i++) {
      Get.back();
      await Future<void>.delayed(const Duration(milliseconds: 120));
    }

    // 再补推差集
    for (var i = common; i < target.length; i++) {
      final n = nodes[target[i]]!;
      if (i > 0 && n.args == null) {
        // 参数在内存里已经没了（比如 app 重启过），跳不过去
        return false;
      }
      _pendingNode = n.id;
      Get.toNamed(n.route, arguments: n.args);
      await Future<void>.delayed(const Duration(milliseconds: 220));
    }
    return true;
  }

  /// 直接回首页：退到根路由，并把底部 tab 切回「首页」。
  ///
  /// 只退到根是不够的 —— 根是 tab 容器，退回去还停在你上次看的那个 tab
  /// （实测停在「我的」）。所以要顺手把 tab 也切过去。
  Future<void> goHome() async {
    final root = rootId;
    if (root != null) await jumpTo(root);
    try {
      if (Get.isRegistered<MainController>()) {
        final main = Get.find<MainController>();
        final i = main.navigationBars.indexOf(NavigationBarType.home);
        // 必须走 setIndex：它除了改 selectedIndex 还会把 PageView 翻过去，
        // 只改 selectedIndex 的话 tab 指示器动了、内容还停在上一个 tab（踩过）
        if (i >= 0) main.setIndex(i);
      }
    } catch (_) {}
  }

  /// 从某个节点重新开始：退到它，之后新开的页面会挂在它下面长新分支
  Future<bool> branchFrom(int id) => jumpTo(id);

  void clear() {
    nodes.clear();
    _routeNode.clear();
    _routeOrder.clear();
    stack.clear();
    _seq = 0;
    version.value++;
  }
}

/// 挂在 `navigatorObservers` 上，把每次页面进出记进历史树。
class ModNavObserver extends GetObserver {
  @override
  void didPush(Route route, Route? previousRoute) {
    super.didPush(route, previousRoute);
    NavHistoryService.to.onPush(route);
  }

  @override
  void didPop(Route route, Route? previousRoute) {
    super.didPop(route, previousRoute);
    NavHistoryService.to.onPop(route);
  }

  @override
  void didRemove(Route route, Route? previousRoute) {
    super.didRemove(route, previousRoute);
    NavHistoryService.to.onRemove(route);
  }

  @override
  void didReplace({Route? newRoute, Route? oldRoute}) {
    super.didReplace(newRoute: newRoute, oldRoute: oldRoute);
    NavHistoryService.to.onReplace(oldRoute, newRoute);
  }
}
