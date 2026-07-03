// 音效服务:每个音效一个 AudioPool 预加载,重放只走 resume()。
//
// 性能要点(彻底修复"越玩越卡"):
// 旧实现每次 play(AssetSource) 都会重新 setSource —— 这会重新加载/解码音频,
// 并在 audioplayers 内部的 _completePrepared 里为"每一次播放"创建一个 Stream
// 订阅 + 超时 Timer。连发、激战时这些开销不断堆积(且平台线程来不及处理),
// 表现为"第一关还行,第二关开始越玩越卡"。
//
// 改用 AudioPool 后:
//  - 每个音效在 init 时一次性 setSource 预加载,之后永不重新加载(无解码、无磁盘);
//  - 重放只调用 start() -> resume(),不再触发 setSource / _completePrepared,
//    彻底消除每发子弹的 Stream+Timer 堆积;
//  - 每个池有 maxPlayers 上限,播放器按需创建、播完归还,数量有界、不会泄漏;
//  - 同名音效做轻量节流(不影响子弹发射速率),避免极速连发的音频洪流。

import 'package:audioplayers/audioplayers.dart';

class SoundService {
  final Map<String, AudioPool> _pools = {};
  final Map<String, double> _vol = {};
  bool muted = false;
  bool _ready = false;

  static const String _dir = 'sounds/';

  // 音效定义:文件名 -> (并发池上限, 默认音量)
  static const Map<String, ({int max, double vol})> _defs = {
    'shoot': (max: 2, vol: 0.40),
    'enemy_shoot': (max: 3, vol: 0.18),
    'hit': (max: 3, vol: 0.30),
    'explosion': (max: 2, vol: 0.50),
    'big_explosion': (max: 1, vol: 0.60),
    'steel': (max: 2, vol: 0.25),
    'powerup': (max: 1, vol: 0.50),
    'start': (max: 1, vol: 0.55),
    'gameover': (max: 1, vol: 0.60),
  };

  // 同名音效节流计时
  final Stopwatch _watch = Stopwatch();
  final Map<String, int> _lastAt = {};

  Future<void> init() async {
    if (_ready) return;
    try {
      for (final e in _defs.entries) {
        final name = e.key;
        final def = e.value;
        try {
          final pool = await AudioPool.createFromAsset(
            path: '$_dir$name.wav',
            maxPlayers: def.max,
          );
          _pools[name] = pool;
          _vol[name] = def.vol;
        } on Object {
          // 单个音效加载失败不影响其余音效与游戏运行
        }
      }
      if (_pools.isNotEmpty) {
        _watch.start();
        _ready = true;
      }
    } on Object {
      _ready = false;
    }
  }

  void play(String name, {double? volume}) {
    if (muted || !_ready) return;
    final pool = _pools[name];
    if (pool == null) return;
    final now = _watch.elapsedMilliseconds;
    if (now - (_lastAt[name] ?? -9999) < 60) return; // 同名节流
    _lastAt[name] = now;
    final vol = volume ?? (_vol[name] ?? 0.5);
    _start(pool, vol); // 不 await,避免阻塞帧循环
  }

  Future<void> _start(AudioPool pool, double vol) async {
    try {
      await pool.start(volume: vol);
    } on Object {
      // 忽略任何音频错误,绝不影响游戏
    }
  }

  void dispose() {
    for (final p in _pools.values) {
      p.dispose(); // 返回 Future,销毁时不阻塞
    }
    _pools.clear();
    _vol.clear();
    _ready = false;
  }
}
