import 'package:PiliPlus/common/widgets/scaffold/simple_scaffold.dart';
import 'package:PiliPlus/mod/settings_sync/sync_service.dart';
import 'package:PiliPlus/utils/feed_back.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:get/get.dart';
import 'package:intl/intl.dart';
import 'package:material_ui/material_ui.dart';

/// 配置同步设置页。
///
/// 服务端见 `mod/server/`（局域网里的一个小 HTTP 服务，按配置名存 JSON）。
class SettingsSyncPage extends StatefulWidget {
  const SettingsSyncPage({super.key});

  @override
  State<SettingsSyncPage> createState() => _SettingsSyncPageState();
}

class _SettingsSyncPageState extends State<SettingsSyncPage> {
  final _svc = SettingsSyncService.to;

  late final TextEditingController _urlCtr = TextEditingController(
    text: SyncConfig.url,
  );
  late final TextEditingController _tokenCtr = TextEditingController(
    text: SyncConfig.token,
  );
  late final TextEditingController _profileCtr = TextEditingController(
    text: SyncConfig.profile,
  );
  late bool _auto = SyncConfig.auto;

  @override
  void dispose() {
    _urlCtr.dispose();
    _tokenCtr.dispose();
    _profileCtr.dispose();
    super.dispose();
  }

  void _saveFields() {
    SyncConfig.url = _urlCtr.text.trim();
    SyncConfig.token = _tokenCtr.text.trim();
    SyncConfig.profile = _profileCtr.text.trim();
  }

  Future<void> _guard(Future<void> Function() action) async {
    _saveFields();
    if (SyncConfig.url.isEmpty) {
      SmartDialog.showToast('请先填服务器地址');
      return;
    }
    try {
      _svc.busy.value = true;
      await action();
      SmartDialog.showToast(_svc.status.value);
    } catch (e) {
      _svc.status.value = '$e';
      SmartDialog.showToast('$e');
    } finally {
      _svc.busy.value = false;
      if (mounted) setState(() {});
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SimpleScaffold(
      appBar: AppBar(title: const Text('配置同步')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 120),
        children: [
          Text(
            '把偏好设置（播放/外观/播放器/倍速规则等）同步到局域网服务端。\n'
            '不包含账号、登录态、观看进度、搜索历史与缓存。',
            style: TextStyle(fontSize: 12, color: theme.colorScheme.outline),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _urlCtr,
            keyboardType: TextInputType.url,
            decoration: const InputDecoration(
              labelText: '服务器地址',
              hintText: 'http://192.168.x.x:8720',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _tokenCtr,
            decoration: const InputDecoration(
              labelText: '口令（服务端没设就留空）',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _profileCtr,
            decoration: const InputDecoration(
              labelText: '配置名',
              hintText: '例如 手机 / 平板 / 客厅',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 8),
          Obx(() {
            final list = _svc.profiles;
            if (list.isEmpty) return const SizedBox.shrink();
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('服务端已有配置（点一下就用它）',
                    style: TextStyle(fontSize: 12, color: theme.colorScheme.outline)),
                const SizedBox(height: 6),
                Wrap(
                  spacing: 8,
                  runSpacing: 4,
                  children: [
                    for (final p in list)
                      ActionChip(
                        label: Text(
                          '${p.name} · rev ${p.rev}'
                          '${p.device.isEmpty ? '' : ' · ${p.device}'}',
                        ),
                        onPressed: () {
                          feedBack();
                          _profileCtr.text = p.name;
                          _saveFields();
                          setState(() {});
                        },
                      ),
                  ],
                ),
              ],
            );
          }),
          const SizedBox(height: 8),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('自动同步'),
            subtitle: const Text('本机改动自动上传；每 20 秒检查远端是否有更新并拉取'),
            value: _auto,
            onChanged: (v) async {
              setState(() => _auto = v);
              SyncConfig.auto = v;
              if (SyncConfig.enabled) {
                await _svc.start();
              }
            },
          ),
          const Divider(),
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: () => _guard(_svc.refreshProfiles),
                  icon: const Icon(Icons.refresh),
                  label: const Text('刷新配置列表'),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: () => _guard(() => _svc.pull(force: true)),
                  icon: const Icon(Icons.download),
                  label: const Text('立即拉取'),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          FilledButton.icon(
            onPressed: () => _guard(_svc.push),
            icon: const Icon(Icons.upload),
            label: const Text('把本机配置上传'),
          ),
          const SizedBox(height: 10),
          Obx(
            () => SyncConfig.enabled
                ? OutlinedButton.icon(
                    onPressed: () async {
                      _svc.stop();
                      setState(() {});
                      SmartDialog.showToast('已关闭自动同步');
                    },
                    icon: const Icon(Icons.stop_circle_outlined),
                    label: const Text('关闭自动同步'),
                  )
                : FilledButton.tonalIcon(
                    onPressed: () => _guard(_svc.start),
                    icon: const Icon(Icons.play_circle_outline),
                    label: const Text('开启自动同步'),
                  ),
          ),
          const SizedBox(height: 20),
          Obx(() {
            final last = SyncConfig.lastSyncAt;
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('状态：${_svc.status.value}'),
                const SizedBox(height: 4),
                Text(
                  '配置名：${SyncConfig.profile.isEmpty ? '（未设置）' : SyncConfig.profile}'
                  '　远端 rev：${SyncConfig.rev}',
                  style: const TextStyle(fontSize: 12),
                ),
                if (last > 0)
                  Text(
                    '上次同步：${DateFormat('MM-dd HH:mm:ss').format(DateTime.fromMillisecondsSinceEpoch(last))}',
                    style: const TextStyle(fontSize: 12),
                  ),
                const SizedBox(height: 8),
                Text(
                  '提示：少数设置（如部分在启动时读取的项）需要重启 App 才完全生效。',
                  style: TextStyle(fontSize: 12, color: theme.colorScheme.outline),
                ),
              ],
            );
          }),
        ],
      ),
    );
  }
}
