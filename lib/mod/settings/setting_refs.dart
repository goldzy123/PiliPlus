import 'package:PiliPlus/models/common/setting_type.dart';
import 'package:PiliPlus/pages/setting/models/model.dart';

class SettingRef {
  final String id;
  final SettingType type;
  final SettingsModel model;

  const SettingRef({
    required this.id,
    required this.type,
    required this.model,
  });
}

Map<String, SettingRef> buildSettingRefs() {
  final map = <String, SettingRef>{};
  for (final type in SettingType.values) {
    if (type == SettingType.webdavSetting || type == SettingType.about) {
      continue;
    }
    for (final model in type.settings) {
      final id = model.effectiveTitle;
      if (id.isEmpty) continue;
      map[id] = SettingRef(id: id, type: type, model: model);
    }
  }
  return map;
}
