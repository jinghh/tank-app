// 音效服务：使用 audioplayers 池化播放，支持静音，全部容错（绝不阻塞游戏）。

import 'package:audioplayers/audioplayers.dart';

class SoundService {
  final List<AudioPlayer> _pool = [];
  int _idx = 0;
  bool muted = false;
  bool _ready = false;

  static const String _dir = 'sounds/';

  Future<void> init() async {
    if (_ready) return;
    try {
      for (int i = 0; i < 5; i++) {
        final p = AudioPlayer();
        await p.setReleaseMode(ReleaseMode.stop);
        await p.setSourceAsset('${_dir}shoot.wav'); // 预热
        _pool.add(p);
      }
      _ready = true;
    } on Object {
      _ready = false;
    }
  }

  void play(String name, {double volume = 0.5}) {
    if (muted || !_ready || _pool.isEmpty) return;
    final p = _pool[_idx % _pool.length];
    _idx++;
    // 不 await，避免阻塞帧循环
    _play(p, name, volume);
  }

  Future<void> _play(AudioPlayer p, String name, double volume) async {
    try {
      await p.setVolume(volume);
      await p.play(AssetSource('$_dir$name.wav'), mode: PlayerMode.lowLatency);
    } on Object {
      // 忽略任何音频错误
    }
  }

  void dispose() {
    for (final p in _pool) {
      p.dispose();
    }
    _pool.clear();
    _ready = false;
  }
}
