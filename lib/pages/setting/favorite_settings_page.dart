import 'package:PiliPlus/common/widgets/scaffold/simple_scaffold.dart';
import 'package:PiliPlus/pages/setting/models/model.dart';
import 'package:PiliPlus/pages/setting/setting_favorites.dart';
import 'package:PiliPlus/pages/setting/setting_refs.dart';
import 'package:material_ui/material_ui.dart';

class FavoriteSettingsPage extends StatefulWidget {
  const FavoriteSettingsPage({super.key});

  @override
  State<FavoriteSettingsPage> createState() => _FavoriteSettingsPageState();
}

class _FavoriteSettingsPageState extends State<FavoriteSettingsPage> {
  late Map<String, SettingRef> refs;

  @override
  void initState() {
    super.initState();
    refs = buildSettingRefs();
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

  Widget _header(String title) {
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
  }) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onLongPress: onLongPress,
      child: Stack(
        children: [
          model.widget,
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
    final favorites = _favoriteRefs();
    final recent = _recentRefs();
    final itemCount =
        (favorites.isEmpty ? 0 : favorites.length + 1) +
        (recent.isEmpty ? 0 : recent.length + 1);

    return SimpleScaffold(
      appBar: AppBar(title: const Text('收藏')),
      body: ListView.builder(
        padding: EdgeInsets.only(
          bottom: MediaQuery.viewPaddingOf(context).bottom + 100,
        ),
        itemCount: itemCount,
        itemBuilder: (context, index) {
          int cursor = 0;
          if (favorites.isNotEmpty) {
            if (index == cursor) return _header('收藏');
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
          if (recent.isNotEmpty) {
            if (index == cursor) return _header('最近修改');
            cursor++;
            final ref = recent[index - cursor];
            return _tile(
              ref.model,
              isFavorite: SettingFavorites.isFavorite(ref.id),
              onLongPress: () => _favoriteFromRecent(ref.id),
            );
          }
          return const SizedBox.shrink();
        },
      ),
    );
  }
}
