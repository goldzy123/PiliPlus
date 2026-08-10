import 'package:PiliPlus/services/lan_sync/lan_sync_service.dart';
import 'package:PiliPlus/services/lan_sync/models.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:get/get.dart';
import 'package:material_ui/material_ui.dart';

class LanSyncPanel extends StatelessWidget {
  const LanSyncPanel({super.key});

  static Future<void> show(BuildContext context) {
    return showModalBottomSheet<void>(
      context: context,
      useSafeArea: true,
      clipBehavior: Clip.hardEdge,
      builder: (context) => const LanSyncPanel(),
    );
  }

  Future<void> _continuePlay(BuildContext context, LanPeer peer) async {
    final state = await LanSyncService.instance.fetchState(peer);
    if (!context.mounted) return;
    if (state == null || state.isEmpty) {
      SmartDialog.showToast('对方暂未播放视频');
      return;
    }
    Get.back();
    LanSyncService.instance.playRemote(state);
  }

  Future<void> _push(BuildContext context, LanPeer peer) async {
    final ok = await LanSyncService.instance.pushState(peer);
    if (!context.mounted) return;
    SmartDialog.showToast(ok ? '已推送' : '推送失败');
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: SizedBox(
        height: MediaQuery.sizeOf(context).height * 0.45,
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.all(12),
              child: Text(
                '局域网设备',
                style: Theme.of(context).textTheme.titleMedium,
              ),
            ),
            Expanded(
              child: Obx(() {
                final peers = LanSyncService.instance.peers;
                if (peers.isEmpty) {
                  return const Center(
                    child: Text('未发现同一账号的安卓设备'),
                  );
                }
                return ListView.builder(
                  itemCount: peers.length,
                  itemBuilder: (context, index) {
                    final peer = peers[index];
                    final title = peer.state.title?.isNotEmpty == true
                        ? peer.state.title!
                        : '未在播放';
                    return ListTile(
                      leading: const Icon(Icons.smartphone),
                      title: Text(peer.deviceName),
                      subtitle: Text(
                        title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      trailing: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          IconButton(
                            tooltip: '继续播放',
                            onPressed: () => _continuePlay(context, peer),
                            icon: const Icon(Icons.play_arrow),
                          ),
                          IconButton(
                            tooltip: '推送至此设备',
                            onPressed: () => _push(context, peer),
                            icon: const Icon(Icons.send),
                          ),
                        ],
                      ),
                    );
                  },
                );
              }),
            ),
          ],
        ),
      ),
    );
  }
}
