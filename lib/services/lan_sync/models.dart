class RemotePlaybackState {
  final String? bvid;
  final int? aid;
  final int? cid;
  final String? title;
  final int? upMid;
  final String? upName;
  final int positionMs;
  final double speed;
  final bool playing;
  final bool live;

  const RemotePlaybackState({
    this.bvid,
    this.aid,
    this.cid,
    this.title,
    this.upMid,
    this.upName,
    this.positionMs = 0,
    this.speed = 1.0,
    this.playing = false,
    this.live = false,
  });

  bool get isEmpty => bvid == null && aid == null && cid == null;

  Map<String, dynamic> toJson() => {
    'bvid': bvid,
    'aid': aid,
    'cid': cid,
    'title': title,
    'upMid': upMid,
    'upName': upName,
    'positionMs': positionMs,
    'speed': speed,
    'playing': playing,
    'live': live,
  };

  factory RemotePlaybackState.fromJson(Map<String, dynamic> json) =>
      RemotePlaybackState(
        bvid: json['bvid'] as String?,
        aid: (json['aid'] as num?)?.toInt(),
        cid: (json['cid'] as num?)?.toInt(),
        title: json['title'] as String?,
        upMid: (json['upMid'] as num?)?.toInt(),
        upName: json['upName'] as String?,
        positionMs: (json['positionMs'] as num?)?.toInt() ?? 0,
        speed: (json['speed'] as num?)?.toDouble() ?? 1.0,
        playing: json['playing'] as bool? ?? false,
        live: json['live'] as bool? ?? false,
      );
}

class LanPeer {
  final String deviceId;
  final String deviceName;
  final int mid;
  final String host;
  final int port;
  final RemotePlaybackState state;
  final DateTime lastSeen;

  const LanPeer({
    required this.deviceId,
    required this.deviceName,
    required this.mid,
    required this.host,
    required this.port,
    required this.state,
    required this.lastSeen,
  });

  LanPeer copyWith({
    RemotePlaybackState? state,
    DateTime? lastSeen,
  }) => LanPeer(
    deviceId: deviceId,
    deviceName: deviceName,
    mid: mid,
    host: host,
    port: port,
    state: state ?? this.state,
    lastSeen: lastSeen ?? this.lastSeen,
  );
}
