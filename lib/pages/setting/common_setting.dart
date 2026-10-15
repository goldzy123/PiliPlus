import 'package:PiliPlus/common/widgets/scaffold/simple_scaffold.dart';
import 'package:PiliPlus/models/common/setting_type.dart';
import 'package:PiliPlus/pages/setting/models/model.dart';
import 'package:PiliPlus/mod/settings/setting_favorites.dart';
import 'package:PiliPlus/mod/settings/setting_refs.dart';
import 'package:material_ui/material_ui.dart';

class CommonSetting extends StatefulWidget {
  const CommonSetting({
    super.key,
    required this.settingType,
    this.showAppBar = true,
  });

  final bool showAppBar;
  final SettingType settingType;

  @override
  State<CommonSetting> createState() => _CommonSettingState();
}

class _CommonSettingState extends State<CommonSetting> {
  late EdgeInsets padding;
  late List<SettingsModel> settings;
  late Map<String, SettingRef> refs;

  void _initSetting() {
    settings = widget.settingType.settings;
    refs = buildSettingRefs();
  }

  @override
  void initState() {
    super.initState();
    _initSetting();
  }

  @override
  void didUpdateWidget(CommonSetting oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.settingType != oldWidget.settingType) {
      _initSetting();
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    padding = MediaQuery.viewPaddingOf(context);
  }

  Future<void> _toggleFavorite(String id) async {
    await SettingFavorites.toggleFavorite(id);
    if (mounted) setState(() {});
  }

  Widget _tile(
    SettingsModel model, {
    required bool isFavorite,
    VoidCallback? onLongPress,
    bool showStar = true,
  }) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onLongPress: onLongPress,
      child: Stack(
        children: [
          model.widget,
          if (showStar)
            Positioned(
              top: 4,
              right: 4,
              child: Icon(
                isFavorite ? Icons.star : Icons.star_border,
                size: 14,
                color: isFavorite ? Colors.amber : Colors.grey,
              ),
            ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final showAppBar = widget.showAppBar;

    // [MOD-HOOK:setting-favorites-scope] 原来这里把「收藏」「最近修改」两块
    // 注入到**每一个**设置列表的顶部（itemCount 里加、itemBuilder 里先渲染），
    // 结果每个页面开头都挂着同样一坨，正常选项要滚半天才看到。
    // 现在这里只渲染本页自己的项；收藏和最近统一收进 /settingFavorites
    // （设置页顶部有入口），互不干扰。
    return SimpleScaffold(
      appBar: showAppBar ? AppBar(title: Text(widget.settingType.title)) : null,
      body: ListView.builder(
        key: ValueKey(widget.settingType),
        padding: EdgeInsets.only(
          left: showAppBar ? padding.left : 0,
          right: showAppBar ? padding.right : 0,
          bottom: padding.bottom + 100,
        ),
        itemCount: settings.length,
        itemBuilder: (context, index) {
          final model = settings[index];
          final id = model.effectiveTitle;
          return _tile(
            model,
            isFavorite: SettingFavorites.isFavorite(id),
            onLongPress: () => _toggleFavorite(id),
          );
        },
      ),
    );
  }
}
