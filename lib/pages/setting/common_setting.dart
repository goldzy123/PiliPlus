import 'package:PiliPlus/common/widgets/scaffold/simple_scaffold.dart';
import 'package:PiliPlus/models/common/setting_type.dart';
import 'package:PiliPlus/pages/setting/models/model.dart';
import 'package:PiliPlus/pages/setting/setting_favorites.dart';
import 'package:PiliPlus/pages/setting/setting_refs.dart';
import 'package:flutter/material.dart';

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

  List<SettingRef> _favoriteRefs() {
    return SettingFavorites.favorites
        .map((id) => refs[id])
        .whereType<SettingRef>()
        .toList();
  }

  List<SettingRef> _recentRefs() {
    return SettingFavorites.recent
        .map((id) => refs[id])
        .whereType<SettingRef>()
        .toList();
  }

  Future<void> _toggleFavorite(String id) async {
    await SettingFavorites.toggleFavorite(id);
    if (mounted) setState(() {});
  }

  Future<void> _favoriteFromRecent(String id) async {
    await SettingFavorites.toggleFavorite(id);
    await SettingFavorites.removeRecent(id);
    if (mounted) setState(() {});
  }

  Widget _sectionHeader(String title) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 6),
      child: Text(
        title,
        style: TextStyle(
          fontSize: 12,
          color: Theme.of(context).colorScheme.outline,
        ),
      ),
    );
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
    final favorites = _favoriteRefs();
    final recent = _recentRefs();
    final hasFav = favorites.isNotEmpty;
    final hasRecent = recent.isNotEmpty;
    final itemCount =
        settings.length +
        (hasFav ? favorites.length + 1 : 0) +
        (hasRecent ? recent.length + 1 : 0);

    return SimpleScaffold(
      appBar: showAppBar ? AppBar(title: Text(widget.settingType.title)) : null,
      body: ListView.builder(
        key: ValueKey(widget.settingType),
        padding: EdgeInsets.only(
          left: showAppBar ? padding.left : 0,
          right: showAppBar ? padding.right : 0,
          bottom: padding.bottom + 100,
        ),
        itemCount: itemCount,
        itemBuilder: (context, index) {
          int cursor = 0;
          if (hasFav) {
            if (index == cursor) return _sectionHeader('收藏');
            cursor++;
            if (index < cursor + favorites.length) {
              final ref = favorites[index - cursor];
              return _tile(
                ref.model,
                isFavorite: true,
                onLongPress: () => _toggleFavorite(ref.id),
              );
            }
            cursor += favorites.length;
          }
          if (hasRecent) {
            if (index == cursor) return _sectionHeader('最近修改');
            cursor++;
            if (index < cursor + recent.length) {
              final ref = recent[index - cursor];
              return _tile(
                ref.model,
                isFavorite: SettingFavorites.isFavorite(ref.id),
                onLongPress: () => _favoriteFromRecent(ref.id),
              );
            }
            cursor += recent.length;
          }
          final model = settings[index - cursor];
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
