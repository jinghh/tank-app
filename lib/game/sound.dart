// 音效服务：使用 audioplayers 池化播放，支持静音，全部容错（绝不阻塞游戏）。
// 性能要点：
//   - 播放器创建时一次性确定 PlayerMode.lowLatency，play() 不再传 mode，
//     否则每次开火都会"切换模式 → 销毁并重建底层播放器"，造成持续卡顿。
//   - 同名音效做轻量节流（不影响子弹发射速率），避免极速连发时的音频堆积。

import 'package:audioplayers/audioplayers.dart';

class SoundService {
  final List<AudioPlayer> _pool = [];
  int _idx = 0;
  bool muted = false;
  bool _ready = false;

  static const String _dir = 'sounds/';

  // 同名音效节流计时
  final Stopwatch _watch = Stopwatch();
  final Map<String, int> _lastAt = {};

  Future<void> init() async {
    if (_ready) return;
    try {
      for (int i = 0; i < 5; i++) {
        // 一次性确定低延迟模式，避免后续 play() 触发播放器重建
        final p = AudioPlayer();
        await p.setPlayerMode(PlayerMode.lowLatency);
        await p.setReleaseMode(ReleaseMode.stop);
        await p.setVolume(0.5);
        _pool.add(p);
      }
      _watch.start();
      _ready = true;
    } on Object {
      _ready = false;
    }
  }

  void play(String name, {double volume = 0.5}) {
    if (muted || !_ready || _pool.isEmpty) return;
    final now = _watch.elapsedMilliseconds;
    if (now - (_lastAt[name] ?? -9999) < 50) return; // 同名节流
    _lastAt[name] = now;
    final p = _pool[_idx % _pool.length];
    _idx++;
    // 不 await，避免阻塞帧循环
    _play(p, name, volume);
  }

  Future<void> _play(AudioPlayer p, String name, double volume) async {
    try {
      await p.setVolume(volume);
      await p.play(AssetSource('$_dir$name.wav')); // 不再传 mode
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
