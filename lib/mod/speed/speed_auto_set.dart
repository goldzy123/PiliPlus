import 'package:PiliPlus/common/widgets/scaffold/simple_scaffold.dart';
import 'package:PiliPlus/mod/speed/playback_speed_service.dart';
import 'package:PiliPlus/plugin/pl_player/controller.dart';
import 'package:PiliPlus/utils/storage.dart';
import 'package:PiliPlus/utils/storage_key.dart';
import 'package:PiliPlus/utils/storage_pref.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:get/get.dart';
import 'package:material_ui/material_ui.dart';

class SpeedAutoSetPage extends StatefulWidget {
  const SpeedAutoSetPage({super.key});

  @override
  State<SpeedAutoSetPage> createState() => _SpeedAutoSetPageState();
}

class _SpeedAutoSetPageState extends State<SpeedAutoSetPage> {
  late bool enableAi = Pref.enableSpeedAi;
  late final TextEditingController _baseUrlCtr = TextEditingController(
    text: Pref.speedAiBaseUrl,
  );
  late final TextEditingController _apiKeyCtr = TextEditingController(
    text: Pref.speedAiApiKey,
  );
  late final TextEditingController _modelCtr = TextEditingController(
    text: Pref.speedAiModel,
  );
  late final List<({String name, double speed})> _categories = [
    for (final entry in Pref.speedAiCategoryMap.entries)
      (name: entry.key, speed: entry.value),
  ];
  late final List<SpeedRule> _rules = [
    for (final rule in Pref.speedRules) SpeedRule.fromJson(rule),
  ];
  late Map<String, double> _upOverrides = PlaybackSpeedService.upOverrides;

  // 播放页那两个快捷倍速按钮的取值
  late double _quick1 = Pref.quickSpeed1;
  late double _quick2 = Pref.quickSpeed2;

  Future<void> _pickQuickSpeed(int index) async {
    final current = index == 0 ? _quick1 : _quick2;
    final res = await showDialog<double>(
      context: context,
      builder: (context) => SimpleDialog(
        title: Text('快捷倍速 ${index + 1}'),
        children: Pref.speedList
            .map(
              (e) => SimpleDialogOption(
                onPressed: () => Navigator.pop(context, e),
                child: Text(
                  '${e == e.roundToDouble() ? e.toStringAsFixed(0) : e}X'
                  '${e == current ? '   ✓' : ''}',
                ),
              ),
            )
            .toList(),
      ),
    );
    if (res == null) return;
    setState(() {
      if (index == 0) {
        _quick1 = res;
      } else {
        _quick2 = res;
      }
    });
    final ctrl = PlPlayerController.instance;
    if (ctrl != null) {
      await ctrl.setQuickSpeed(index, res);
    } else {
      await GStorage.video.put(
        index == 0 ? VideoBoxKey.quickSpeed1 : VideoBoxKey.quickSpeed2,
        res,
      );
    }
  }

  @override
  void dispose() {
    _baseUrlCtr.dispose();
    _apiKeyCtr.dispose();
    _modelCtr.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    await GStorage.setting.put(SettingBoxKey.enableSpeedAi, enableAi);
    await GStorage.setting.put(
      SettingBoxKey.speedAiBaseUrl,
      _baseUrlCtr.text.trim(),
    );
    await GStorage.setting.put(
      SettingBoxKey.speedAiApiKey,
      _apiKeyCtr.text.trim(),
    );
    await GStorage.setting.put(
      SettingBoxKey.speedAiModel,
      _modelCtr.text.trim(),
    );
    await GStorage.setting.put(
      SettingBoxKey.speedAiCategoryMap,
      {
        for (final item in _categories)
          if (item.name.trim().isNotEmpty) item.name.trim(): item.speed,
      },
    );
    await GStorage.setting.put(
      SettingBoxKey.speedRules,
      [for (final rule in _rules) rule.toJson()],
    );
    if (mounted) {
      SmartDialog.showToast('已保存');
    }
  }

  void _addCategory() {
    final nameCtr = TextEditingController();
    final speedCtr = TextEditingController(text: '1.0');
    showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('添加类别'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: nameCtr,
              decoration: const InputDecoration(labelText: '类别名'),
            ),
            TextField(
              controller: speedCtr,
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
              ),
              decoration: const InputDecoration(labelText: '倍速'),
            ),
          ],
        ),
        actions: [
          TextButton(onPressed: Get.back, child: const Text('取消')),
          TextButton(
            onPressed: () {
              final speed = double.tryParse(speedCtr.text);
              if (nameCtr.text.trim().isNotEmpty && speed != null) {
                setState(() {
                  _categories.add((name: nameCtr.text.trim(), speed: speed));
                });
              }
              Get.back();
            },
            child: const Text('确认'),
          ),
        ],
      ),
    );
  }

  void _addRule() {
    final keywordCtr = TextEditingController();
    final speedCtr = TextEditingController(text: '1.0');
    showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('添加本地规则'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: keywordCtr,
              decoration: const InputDecoration(labelText: '关键词'),
            ),
            TextField(
              controller: speedCtr,
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
              ),
              decoration: const InputDecoration(labelText: '倍速'),
            ),
          ],
        ),
        actions: [
          TextButton(onPressed: Get.back, child: const Text('取消')),
          TextButton(
            onPressed: () {
              final speed = double.tryParse(speedCtr.text);
              if (keywordCtr.text.trim().isNotEmpty && speed != null) {
                setState(() {
                  _rules.add(
                    SpeedRule(keyword: keywordCtr.text.trim(), speed: speed),
                  );
                });
              }
              Get.back();
            },
            child: const Text('确认'),
          ),
        ],
      ),
    );
  }

  Future<void> _addUpOverride() async {
    final midCtr = TextEditingController();
    final speedCtr = TextEditingController(text: '1.5');
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('添加UP倍速覆盖'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: midCtr,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(labelText: 'UP mid'),
            ),
            TextField(
              controller: speedCtr,
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
              ),
              decoration: const InputDecoration(labelText: '倍速'),
            ),
          ],
        ),
        actions: [
          TextButton(onPressed: Get.back, child: const Text('取消')),
          TextButton(
            onPressed: () {
              final mid = int.tryParse(midCtr.text);
              final speed = double.tryParse(speedCtr.text);
              if (mid != null && speed != null) {
                PlaybackSpeedService.setUpSpeed(mid: mid, speed: speed);
                setState(() {
                  _upOverrides = PlaybackSpeedService.upOverrides;
                });
              }
              Get.back();
            },
            child: const Text('确认'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return SimpleScaffold(
      appBar: AppBar(title: const Text('智能倍速')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 120),
        children: [
          const Text(
            '快捷倍速按钮',
            style: TextStyle(fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 2),
          const Text(
            '播放页 UP 主那一行（竖屏）/ 全屏控制条里的两个按钮：\n'
            '点按切换倍速，长按设为该 UP 的强制倍速（再长按一次取消）',
            style: TextStyle(fontSize: 12),
          ),
          ListTile(
            dense: true,
            title: const Text('快捷倍速 1'),
            trailing: Text(
              '${_quick1 == _quick1.roundToDouble() ? _quick1.toStringAsFixed(0) : _quick1}X',
            ),
            onTap: () => _pickQuickSpeed(0),
          ),
          ListTile(
            dense: true,
            title: const Text('快捷倍速 2'),
            trailing: Text(
              '${_quick2 == _quick2.roundToDouble() ? _quick2.toStringAsFixed(0) : _quick2}X',
            ),
            onTap: () => _pickQuickSpeed(1),
          ),
          const Divider(height: 28),
          SwitchListTile(
            title: const Text('启用AI分类'),
            subtitle: const Text('未命中本地规则时调用你配置的接口识别UP类别'),
            value: enableAi,
            onChanged: (value) => setState(() => enableAi = value),
          ),
          TextField(
            controller: _baseUrlCtr,
            decoration: const InputDecoration(
              labelText: 'API地址',
              hintText: 'https://api.openai.com/v1',
            ),
          ),
          TextField(
            controller: _apiKeyCtr,
            obscureText: true,
            decoration: const InputDecoration(labelText: 'API Key'),
          ),
          TextField(
            controller: _modelCtr,
            decoration: const InputDecoration(labelText: '模型'),
          ),
          const SizedBox(height: 20),
          Row(
            children: [
              const Expanded(
                child: Text(
                  '类别倍速',
                  style: TextStyle(fontWeight: FontWeight.w600),
                ),
              ),
              IconButton(
                tooltip: '添加',
                onPressed: _addCategory,
                icon: const Icon(Icons.add),
              ),
            ],
          ),
          for (var i = 0; i < _categories.length; i++)
            Row(
              children: [
                Expanded(
                  flex: 2,
                  child: TextField(
                    controller: TextEditingController(
                      text: _categories[i].name,
                    ),
                    onChanged: (value) => setState(
                      () => _categories[i] = (
                        name: value,
                        speed: _categories[i].speed,
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: TextField(
                    controller: TextEditingController(
                      text: _categories[i].speed.toString(),
                    ),
                    keyboardType: const TextInputType.numberWithOptions(
                      decimal: true,
                    ),
                    onChanged: (value) {
                      final speed = double.tryParse(value);
                      if (speed != null) {
                        setState(
                          () => _categories[i] = (
                            name: _categories[i].name,
                            speed: speed,
                          ),
                        );
                      }
                    },
                  ),
                ),
                IconButton(
                  tooltip: '删除',
                  onPressed: () => setState(() => _categories.removeAt(i)),
                  icon: const Icon(Icons.delete_outline),
                ),
              ],
            ),
          const SizedBox(height: 20),
          Row(
            children: [
              const Expanded(
                child: Text(
                  '本地规则',
                  style: TextStyle(fontWeight: FontWeight.w600),
                ),
              ),
              IconButton(
                tooltip: '添加',
                onPressed: _addRule,
                icon: const Icon(Icons.add),
              ),
            ],
          ),
          for (var i = 0; i < _rules.length; i++)
            Row(
              children: [
                Expanded(
                  flex: 2,
                  child: TextField(
                    controller: TextEditingController(text: _rules[i].keyword),
                    onChanged: (value) => setState(() {
                      _rules[i] = SpeedRule(
                        keyword: value,
                        speed: _rules[i].speed,
                      );
                    }),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: TextField(
                    controller: TextEditingController(
                      text: _rules[i].speed.toString(),
                    ),
                    keyboardType: const TextInputType.numberWithOptions(
                      decimal: true,
                    ),
                    onChanged: (value) {
                      final speed = double.tryParse(value);
                      if (speed != null) {
                        setState(
                          () => _rules[i] = SpeedRule(
                            keyword: _rules[i].keyword,
                            speed: speed,
                          ),
                        );
                      }
                    },
                  ),
                ),
                IconButton(
                  tooltip: '删除',
                  onPressed: () => setState(() => _rules.removeAt(i)),
                  icon: const Icon(Icons.delete_outline),
                ),
              ],
            ),
          const SizedBox(height: 20),
          Row(
            children: [
              const Expanded(
                child: Text(
                  'UP倍速覆盖',
                  style: TextStyle(fontWeight: FontWeight.w600),
                ),
              ),
              IconButton(
                tooltip: '添加',
                onPressed: _addUpOverride,
                icon: const Icon(Icons.add),
              ),
            ],
          ),
          for (final entry in _upOverrides.entries.toList())
            ListTile(
              contentPadding: EdgeInsets.zero,
              title: Text(
                PlaybackSpeedService.upName(int.tryParse(entry.key) ?? 0) ??
                    entry.key,
              ),
              subtitle: Text('mid: ${entry.key}'),
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text('${entry.value}X'),
                  IconButton(
                    tooltip: '删除',
                    onPressed: () async {
                      final mid = int.tryParse(entry.key);
                      if (mid != null) {
                        await PlaybackSpeedService.removeUpSpeed(mid);
                        setState(() {
                          _upOverrides = PlaybackSpeedService.upOverrides;
                        });
                      }
                    },
                    icon: const Icon(Icons.delete_outline),
                  ),
                ],
              ),
            ),
          const SizedBox(height: 30),
          FilledButton(
            onPressed: _save,
            child: const Text('保存'),
          ),
        ],
      ),
    );
  }
}
