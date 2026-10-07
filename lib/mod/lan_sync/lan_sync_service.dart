import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:PiliPlus/models/common/video/video_type.dart';
import 'package:PiliPlus/plugin/pl_player/controller.dart';
import 'package:PiliPlus/mod/lan_sync/models.dart';
import 'package:PiliPlus/utils/accounts.dart';
import 'package:PiliPlus/utils/id_utils.dart';
import 'package:PiliPlus/utils/page_utils.dart';
import 'package:PiliPlus/utils/storage.dart';
import 'package:dio/dio.dart';
import 'package:get/get.dart';
import 'package:uuid/uuid.dart';

class LanSyncService {
  LanSyncService._();

  static final LanSyncService instance = LanSyncService._();

  static const int port = 47888;
  static const String _protocol = 'piliplus_lan_v1';

  final RxList<LanPeer> peers = RxList<LanPeer>();
  final RxBool running = false.obs;

  HttpServer? _server;
  RawDatagramSocket? _socket;
  Timer? _broadcastTimer;
  Timer? _cleanupTimer;
  bool _started = false;
  String? _deviceId;
  String _deviceName = '';
  List<InternetAddress> _broadcastAddresses = [];

  Future<void> start() async {
    if (_started || !Platform.isAndroid) return;
    _started = true;
    _deviceId ??= _loadOrCreateDeviceId();
    _deviceName = Platform.localHostname;

    try {
      _server = await HttpServer.bind(InternetAddress.anyIPv4, port);
      _server!.listen(_handleHttp);
    } catch (_) {}

    try {
      _socket = await RawDatagramSocket.bind(
        InternetAddress.anyIPv4,
        port,
        reuseAddress: true,
        reusePort: true,
      );
      _socket!.broadcastEnabled = true;
      _socket!.listen(_handleSocketEvent);
    } catch (_) {}

    _broadcastTimer = Timer.periodic(
      const Duration(seconds: 2),
      (_) => _broadcast(),
    );
    _cleanupTimer = Timer.periodic(
      const Duration(seconds: 5),
      (_) => _cleanupPeers(),
    );
    running.value = true;
  }

  Future<void> stop() async {
    _started = false;
    _broadcastTimer?.cancel();
    _cleanupTimer?.cancel();
    _broadcastTimer = null;
    _cleanupTimer = null;
    await _server?.close(force: true);
    _socket?.close();
    _server = null;
    _socket = null;
    peers.clear();
    running.value = false;
  }

  RemotePlaybackState _currentState() {
    final controller = PlPlayerController.instance;
    if (controller == null ||
        controller.videoBvid == null ||
        controller.videoCid == null ||
        controller.isLive) {
      return const RemotePlaybackState();
    }
    return RemotePlaybackState(
      bvid: controller.videoBvid,
      aid: controller.aid,
      cid: controller.videoCid,
      title: controller.currentVideoTitle,
      upMid: controller.videoUpMid,
      upName: controller.videoUpName,
      positionMs: controller.positionInMilliseconds,
      speed: controller.playbackSpeed,
      playing: controller.playerStatus.isPlaying,
    );
  }

  Future<void> _broadcast() async {
    if (_socket == null || !Accounts.main.isLogin) return;
    if (_broadcastAddresses.isEmpty) {
      await _refreshBroadcastAddresses();
    }
    final data = utf8.encode(
      jsonEncode({
        'type': _protocol,
        'deviceId': _deviceId,
        'deviceName': _deviceName,
        'mid': Accounts.main.mid,
        'port': port,
        'state': _currentState().toJson(),
      }),
    );
    final targets = <InternetAddress>[
      ..._broadcastAddresses,
      InternetAddress('255.255.255.255'),
    ];
    for (final target in targets) {
      try {
        _socket!.send(data, target, port);
      } catch (_) {}
    }
  }

  Future<void> _refreshBroadcastAddresses() async {
    try {
      final interfaces = await NetworkInterface.list(
        type: InternetAddressType.IPv4,
        includeLoopback: false,
      );
      final addresses = <InternetAddress>[];
      for (final interface in interfaces) {
        for (final address in interface.addresses) {
          if (address.isLoopback) continue;
          final parts = address.address.split('.');
          if (parts.length == 4) {
            parts[3] = '255';
            addresses.add(InternetAddress(parts.join('.')));
          }
        }
      }
      _broadcastAddresses = addresses;
    } catch (_) {}
  }

  void _handleSocketEvent(RawSocketEvent event) {
    if (event != RawSocketEvent.read) return;
    final datagram = _socket?.receive();
    if (datagram == null) return;
    try {
      final decoded = jsonDecode(
        utf8.decode(datagram.data, allowMalformed: true),
      );
      if (decoded is! Map<String, dynamic>) return;
      if (decoded['type'] != _protocol) return;
      final deviceId = decoded['deviceId']?.toString();
      final mid = (decoded['mid'] as num?)?.toInt();
      if (deviceId == null ||
          mid == null ||
          deviceId == _deviceId ||
          mid != Accounts.main.mid) {
        return;
      }
      final stateJson = decoded['state'];
      final state = stateJson is Map<String, dynamic>
          ? RemotePlaybackState.fromJson(stateJson)
          : const RemotePlaybackState();
      final peer = LanPeer(
        deviceId: deviceId,
        deviceName: decoded['deviceName']?.toString() ?? '安卓设备',
        mid: mid,
        host: datagram.address.address,
        port: (decoded['port'] as num?)?.toInt() ?? port,
        state: state,
        lastSeen: DateTime.now(),
      );
      final index = peers.indexWhere((item) => item.deviceId == deviceId);
      if (index >= 0) {
        peers[index] = peer;
      } else {
        peers.add(peer);
      }
    } catch (_) {}
  }

  void _cleanupPeers() {
    final now = DateTime.now();
    peers.removeWhere(
      (peer) => now.difference(peer.lastSeen) > const Duration(seconds: 8),
    );
  }

  Future<void> _handleHttp(HttpRequest request) async {
    final response = request.response;
    response.headers.contentType = ContentType.json;
    try {
      if (request.method == 'GET' && request.uri.path == '/state') {
        response.write(jsonEncode(_currentState().toJson()));
      } else if (request.method == 'POST' && request.uri.path == '/play') {
        final body = await utf8.decoder.bind(request).join();
        final state = RemotePlaybackState.fromJson(
          jsonDecode(body) as Map<String, dynamic>,
        );
        response.write(jsonEncode({'ok': await playRemote(state)}));
      } else {
        response
          ..statusCode = HttpStatus.notFound
          ..write(jsonEncode({'ok': false}));
      }
    } catch (_) {
      response
        ..statusCode = HttpStatus.badRequest
        ..write(jsonEncode({'ok': false}));
    } finally {
      await response.close();
    }
  }

  Future<RemotePlaybackState?> fetchState(LanPeer peer) async {
    try {
      final response = await Dio().get(
        'http://${peer.host}:${peer.port}/state',
        options: Options(
          sendTimeout: const Duration(seconds: 3),
          receiveTimeout: const Duration(seconds: 3),
        ),
      );
      return RemotePlaybackState.fromJson(
        response.data as Map<String, dynamic>,
      );
    } catch (_) {
      return null;
    }
  }

  Future<bool> pushState(LanPeer peer) async {
    final state = _currentState();
    if (state.isEmpty) return false;
    try {
      await Dio().post(
        'http://${peer.host}:${peer.port}/play',
        data: state.toJson(),
        options: Options(
          headers: {'Content-Type': 'application/json'},
          sendTimeout: const Duration(seconds: 3),
          receiveTimeout: const Duration(seconds: 3),
        ),
      );
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<bool> playRemote(RemotePlaybackState state) async {
    if (state.live || state.bvid == null || state.cid == null) return false;
    final bvid = state.bvid!;
    PageUtils.toVideoPage(
      videoType: VideoType.ugc,
      aid: state.aid ?? IdUtils.bv2av(bvid),
      bvid: bvid,
      cid: state.cid!,
      title: state.title,
      progress: state.positionMs > 1000 ? state.positionMs : null,
      extraArguments: {'speed': state.speed},
    );
    return true;
  }

  String _loadOrCreateDeviceId() {
    final box = GStorage.setting;
    var deviceId = box.get('lanDeviceId') as String?;
    if (deviceId == null || deviceId.isEmpty) {
      deviceId = const Uuid().v4();
      box.put('lanDeviceId', deviceId);
    }
    return deviceId;
  }
}
