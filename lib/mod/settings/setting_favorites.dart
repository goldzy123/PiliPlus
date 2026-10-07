import 'package:PiliPlus/utils/storage.dart';
import 'package:hive_ce/hive.dart';

abstract final class SettingFavorites {
  static const _favoriteKey = 'favoriteSettingIds';
  static const _recentKey = 'recentSettingIds';
  static const int maxRecent = 20;

  static Box get _box => GStorage.setting;

  static List<String> _getList(String key) =>
      List<String>.from(_box.get(key, defaultValue: <String>[]));

  static List<String> get favorites => _getList(_favoriteKey);

  static List<String> get recent => _getList(_recentKey);

  static bool isFavorite(String id) => favorites.contains(id);

  static Future<void> toggleFavorite(String id) async {
    final list = _getList(_favoriteKey);
    if (list.contains(id)) {
      list.remove(id);
    } else {
      list.add(id);
    }
    await _box.put(_favoriteKey, list);
  }

  static Future<void> recordRecent(String id) async {
    if (id.isEmpty) return;
    final list = _getList(_recentKey)
      ..remove(id)
      ..insert(0, id);
    if (list.length > maxRecent) {
      list.removeRange(maxRecent, list.length);
    }
    await _box.put(_recentKey, list);
  }

  static Future<void> removeRecent(String id) async {
    final list = _getList(_recentKey)..remove(id);
    await _box.put(_recentKey, list);
  }
}
