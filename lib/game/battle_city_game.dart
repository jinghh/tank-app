// 坦克大战 - 纯移动端交互版（含双人合作）
// 控制：左半屏拖动 = 虚拟摇杆（4 向移动）；右下按钮 = 开火（按下即时发射，按住连发）。
// 双人合作：P1 左半屏、P2 右半屏，各自摇杆 + 开火；共享生命与得分。

import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import 'constants.dart';
import 'maps.dart';
import 'models.dart';
import 'painter.dart';
import 'sound.dart';

class BattleCityGame extends StatefulWidget {
  const BattleCityGame({super.key});

  @override
  State<BattleCityGame> createState() => _BattleCityGameState();
}

class _BattleCityGameState extends State<BattleCityGame>
    with SingleTickerProviderStateMixin {
  // ---- 场景数据 ----
  late List<List<Terrain>> grid;
  final List<Tank> players = [];
  final List<Tank> enemies = [];
  final List<Bullet> bullets = [];
  final List<Explosion> explosions = [];
  final List<PowerUp> powerups = [];

  // ---- 状态 ----
  Phase phase = Phase.start;
  bool _twoPlayer = false;
  int level = 0;
  int score = 0;
  int lives = kStartLives;
  bool baseAlive = true;
  int _terrainVersion = 0; // 地形变化版本号，驱动静态层按需重绘

  late List<EnemyKind> _queue;
  late Set<int> _bonusSet;
  int _spawned = 0;
  int _killed = 0;
  int _spawnCursor = 0;
  double _spawnTimer = 0;
  double _levelClearTimer = 0;
  int _levelClearStartScore = 0;
  int _levelClearBonus = 0;

  double _freezeTime = 0;
  double _shovelTime = 0;
  double _time = 0;

  final Random _rng = Random();
  final FocusNode _focus = FocusNode();
  final SoundService _sound = SoundService();

  // 输入：P1 / P2 各自方向与开火
  Dir? _dir1, _dir2;
  bool _fire1 = false, _fire2 = false;

  late final Rect baseRect;
  late final List<Point<int>> baseArmorCells;

  late final Ticker _ticker;
  Duration? _lastElapsed;

  // ---- 生命周期 ----
  @override
  void initState() {
    super.initState();
    baseRect = Rect.fromLTWH(
      cellToWorld(kBaseCol),
      cellToWorld(kBaseRow),
      kCell * 2,
      kCell * 2,
    );
    baseArmorCells = _computeArmorCells();
    loadLevel(0, twoPlayer: false); // 菜单背景板
    _ticker = createTicker(_onTick);
    _ticker.start();
    WakelockPlus.enable();
    _sound.init();
  }

  @override
  void dispose() {
    _ticker.dispose();
    _focus.dispose();
    _sound.dispose();
    WakelockPlus.disable();
    super.dispose();
  }

  List<Point<int>> _computeArmorCells() {
    final cells = <Point<int>>[];
    for (int x = kBaseCol - 1; x <= kBaseCol + 2; x++) {
      cells.add(Point(x, kBaseRow - 1));
    }
    for (int y = kBaseRow; y <= kBaseRow + 1; y++) {
      cells.add(Point(kBaseCol - 1, y));
      cells.add(Point(kBaseCol + 2, y));
    }
    return cells;
  }

  // ---- 关卡加载 ----
  void loadLevel(int n, {bool? twoPlayer}) {
    if (twoPlayer != null) _twoPlayer = twoPlayer;
    level = n;
    final map = kLevels[n % kLevels.length];
    grid = parseTerrain(map);
    enemies.clear();
    bullets.clear();
    explosions.clear();
    powerups.clear();
    players.clear();
    _freezeTime = 0;
    _shovelTime = 0;
    baseAlive = true;
    _terrainVersion++;

    _clearArea(kPlayerSpawnCol, kPlayerSpawnRow);
    if (_twoPlayer) _clearArea(kPlayer2SpawnCol, kPlayerSpawnRow);
    for (final c in kEnemySpawnColChoices) {
      _clearArea(c, 0);
    }
    _clearArea(kBaseCol, kBaseRow);

    _queue = enemyQueueForLevel(n + 1, _rng);
    _bonusSet = bonusIndices(_queue);
    _spawned = 0;
    _killed = 0;
    _spawnCursor = 0;
    _spawnTimer = 1.2;

    applyBaseArmor(false);

    players.add(_makePlayer(kPlayerSpawnCol, 0));
    if (_twoPlayer) players.add(_makePlayer(kPlayer2SpawnCol, 1));
  }

  Tank _makePlayer(int col, int p) => Tank(
        pos: Offset(cellToWorld(col), cellToWorld(kPlayerSpawnRow)),
        dir: Dir.up,
        isPlayer: true,
        speed: kPlayerSpeed,
        player: p,
      );

  void _clearArea(int col, int row) {
    for (int y = row; y < row + 2 && y < kCells; y++) {
      for (int x = col; x < col + 2 && x < kCells; x++) {
        if (x >= 0 && y >= 0) grid[y][x] = Terrain.empty;
      }
    }
  }

  void applyBaseArmor(bool steel) {
    for (final c in baseArmorCells) {
      if (c.x >= 0 && c.x < kCells && c.y >= 0 && c.y < kCells) {
        grid[c.y][c.x] = steel ? Terrain.steel : Terrain.brick;
      }
    }
    _terrainVersion++;
  }

  void startGame({required bool twoPlayer}) {
    _twoPlayer = twoPlayer;
    score = 0;
    lives = twoPlayer ? 5 : kStartLives;
    loadLevel(0, twoPlayer: twoPlayer);
    phase = Phase.playing;
    _sound.play('start');
  }

  // ---- 帧循环 ----
  void _onTick(Duration elapsed) {
    double dt = 0;
    if (_lastElapsed != null) {
      dt = (elapsed - _lastElapsed!).inMicroseconds / 1e6;
      if (dt > 1 / 30) dt = 1 / 30;
      if (dt < 0) dt = 0;
    }
    _lastElapsed = elapsed;
    _time += dt;

    switch (phase) {
      case Phase.playing:
        update(dt);
        break;
      case Phase.levelClear:
        _levelClearTimer -= dt;
        if (_levelClearTimer <= 0) _advanceLevel();
        break;
      case Phase.start:
      case Phase.paused:
      case Phase.gameOver:
      case Phase.victory:
        break;
    }
    // 仅在需要动画的阶段触发重建，菜单/暂停时静止（省电、减负）
    if (mounted && phase != Phase.start && phase != Phase.paused) {
      setState(() {});
    }
  }

  void _advanceLevel() {
    if (level + 1 >= kLevels.length) {
      phase = Phase.victory;
      _sound.play('start');
    } else {
      loadLevel(level + 1);
      phase = Phase.playing;
      _sound.play('start');
    }
  }

  // ---- 主更新 ----
  void update(double dt) {
    if (_freezeTime > 0) _freezeTime = max(0, _freezeTime - dt);
    if (_shovelTime > 0) {
      _shovelTime = max(0, _shovelTime - dt);
      if (_shovelTime == 0) applyBaseArmor(false);
    }

    for (final p in players) {
      if (!p.alive) continue;
      p.shieldTime = max(0, p.shieldTime - dt);
      final dir = _effectiveDir(p.player);
      if (dir != null) {
        _tryMoveTank(p, dir, p.speed * dt);
      }
      if (_effectiveFire(p.player)) {
        _fire(p);
      }
    }

    _updateSpawning(dt);

    final frozen = _freezeTime > 0;
    for (final e in enemies) {
      _updateEnemy(e, dt, frozen);
    }

    _updateBullets(dt);

    for (final ex in explosions) {
      ex.t += dt;
    }
    explosions.removeWhere((e) => e.done);

    for (final pu in powerups) {
      pu.life -= dt;
      for (final p in players) {
        if (p.alive && p.rect.overlaps(pu.rect)) {
          _applyPowerUp(p, pu.kind);
          pu.life = -1;
          break;
        }
      }
    }
    powerups.removeWhere((pu) => pu.life <= 0);

    // 移除已击毁的敌方坦克，避免"幽灵坦克"
    enemies.removeWhere((e) => !e.alive);

    _checkProgress();
  }

  // ---- 输入汇总 ----
  Dir? _effectiveDir(int p) {
    if (p == 0) {
      final kb = _keyboardDir();
      if (kb != null) return kb;
      return _dir1;
    }
    return _dir2;
  }

  Dir? _keyboardDir() {
    final kb = HardwareKeyboard.instance;
    bool up = kb.logicalKeysPressed.contains(LogicalKeyboardKey.arrowUp) ||
        kb.logicalKeysPressed.contains(LogicalKeyboardKey.keyW);
    bool down = kb.logicalKeysPressed.contains(LogicalKeyboardKey.arrowDown) ||
        kb.logicalKeysPressed.contains(LogicalKeyboardKey.keyS);
    bool left = kb.logicalKeysPressed.contains(LogicalKeyboardKey.arrowLeft) ||
        kb.logicalKeysPressed.contains(LogicalKeyboardKey.keyA);
    bool right = kb.logicalKeysPressed.contains(LogicalKeyboardKey.arrowRight) ||
        kb.logicalKeysPressed.contains(LogicalKeyboardKey.keyD);
    if (up) return Dir.up;
    if (down) return Dir.down;
    if (left) return Dir.left;
    if (right) return Dir.right;
    return null;
  }

  bool _effectiveFire(int p) {
    if (p == 0) {
      final kb = HardwareKeyboard.instance;
      if (kb.logicalKeysPressed.contains(LogicalKeyboardKey.space) ||
          kb.logicalKeysPressed.contains(LogicalKeyboardKey.keyJ)) {
        return true;
      }
      return _fire1;
    }
    return _fire2;
  }

  // ---- 坦克移动 ----
  void _tryMoveTank(Tank t, Dir d, double dist) {
    if (d != t.dir) {
      t.dir = d;
      final snapped = d.isHorizontal
          ? Offset(t.pos.dx, snapToCell(t.pos.dy))
          : Offset(snapToCell(t.pos.dx), t.pos.dy);
      if (!_tankBlocked(Rect.fromLTWH(snapped.dx, snapped.dy, kTank, kTank), t)) {
        t.pos = snapped;
      }
    }
    final np = t.pos + d.vector * dist;
    if (!_tankBlocked(Rect.fromLTWH(np.dx, np.dy, kTank, kTank), t)) {
      t.pos = np;
    }
  }

  bool _tankBlocked(Rect r, Tank self) {
    if (r.left < 0 || r.top < 0 || r.right > kBattle || r.bottom > kBattle) {
      return true;
    }
    if (baseAlive && r.overlaps(baseRect)) return true;
    final x0 = worldToCell(r.left);
    final x1 = worldToCell(r.right - 0.001);
    final y0 = worldToCell(r.top);
    final y1 = worldToCell(r.bottom - 0.001);
    for (int y = y0; y <= y1; y++) {
      for (int x = x0; x <= x1; x++) {
        if (grid[y][x].blocksTank) return true;
      }
    }
    // 玩家之间互相阻挡；敌方也会被任意玩家阻挡
    for (final q in players) {
      if (!identical(q, self) && q.alive && !q.spawning && q.rect.overlaps(r)) {
        return true;
      }
    }
    // 玩家还会被敌方阻挡（敌方之间不互挡，保持原版）
    if (self.isPlayer) {
      for (final e in enemies) {
        if (e.alive && !e.spawning && e.rect.overlaps(r)) return true;
      }
    }
    return false;
  }

  // ---- 开火 ----
  void _fire(Tank t) {
    final tip = t.center + t.dir.vector * (kTank / 2);
    final bp = tip - const Offset(kBullet / 2, kBullet / 2);
    if (t.isPlayer) {
      final maxB = t.bulletLevel >= 2 ? 2 : 1;
      final active = bullets
          .where((b) => b.fromPlayer && b.owner == t.player && !b.dead)
          .length;
      if (active >= maxB) return; // 场上该玩家子弹数已达上限
      final fast = t.bulletLevel >= 1;
      bullets.add(Bullet(
        pos: bp,
        dir: t.dir,
        fromPlayer: true,
        owner: t.player,
        speed: fast ? kBulletSpeedFast : kBulletSpeed,
        power: t.bulletLevel >= 3 ? 3 : 0,
      ));
      _sound.play('shoot', volume: 0.4);
      HapticFeedback.lightImpact();
    } else {
      bullets.add(Bullet(
        pos: bp,
        dir: t.dir,
        fromPlayer: false,
        speed: t.kind == EnemyKind.power ? kBulletSpeedFast : kBulletSpeed,
      ));
      _sound.play('enemy_shoot', volume: 0.18);
    }
  }

  // ---- 敌人出生 ----
  void _updateSpawning(double dt) {
    if (_spawned >= _queue.length) return;
    if (enemies.where((e) => !e.spawning).length >= kMaxEnemiesOnField) return;
    _spawnTimer -= dt;
    if (_spawnTimer > 0) return;

    final col = kEnemySpawnColChoices[_spawnCursor % kEnemySpawnColChoices.length];
    _spawnCursor++;
    final pos = Offset(cellToWorld(col), 0);
    final rect = Rect.fromLTWH(pos.dx, pos.dy, kTank, kTank);

    bool blocked = false;
    for (final e in enemies) {
      if (e.rect.overlaps(rect)) {
        blocked = true;
        break;
      }
    }
    if (!blocked) {
      for (final p in players) {
        if (p.alive && p.rect.overlaps(rect)) {
          blocked = true;
          break;
        }
      }
    }
    if (blocked) {
      _spawnTimer = 0.4;
      return;
    }

    final kind = _queue[_spawned];
    final bonus = _bonusSet.contains(_spawned);
    final speed = kind == EnemyKind.fast ? kEnemySpeedFast : kEnemySpeedBasic;
    enemies.add(Tank(
      pos: pos,
      dir: Dir.down,
      isPlayer: false,
      kind: kind,
      speed: speed,
      bonus: bonus,
    )..spawning = true);
    _spawned++;
    _spawnTimer = 1.8;
  }

  // ---- 敌人 AI ----
  void _updateEnemy(Tank e, double dt, bool frozen) {
    if (!e.alive) return; // 已击毁：本帧起不再行动（update 末尾统一移除）
    if (e.spawning) {
      e.spawnAnim += dt;
      if (e.spawnAnim > 0.7) e.spawning = false;
      return;
    }
    e.shieldTime = max(0, e.shieldTime - dt);
    e.fireCooldown = max(0, e.fireCooldown - dt);
    if (frozen) return;

    e.aiTimer -= dt;
    if (e.aiTimer <= 0) {
      e.dir = _pickEnemyDir(e);
      e.aiTimer = 0.5 + _rng.nextDouble() * 1.3;
    }

    final before = e.pos.dx + e.pos.dy;
    _tryMoveTank(e, e.dir, e.speed * dt);
    final moved = (e.pos.dx + e.pos.dy) - before;
    if (moved.abs() < 0.01) {
      e.aiTimer = 0;
    }

    if (e.fireCooldown <= 0) {
      _fire(e);
      e.fireCooldown = kEnemyFireCooldown * (0.5 + _rng.nextDouble());
    }
  }

  Tank? _nearestPlayer(Tank e) {
    Tank? best;
    double bd = 1e18;
    for (final p in players) {
      if (!p.alive) continue;
      final d = (p.center.dx - e.center.dx).abs() +
          (p.center.dy - e.center.dy).abs();
      if (d < bd) {
        bd = d;
        best = p;
      }
    }
    return best;
  }

  Dir _pickEnemyDir(Tank e) {
    final p = _nearestPlayer(e);
    if (p != null && _rng.nextDouble() < 0.5) {
      final dx = p.center.dx - e.center.dx;
      final dy = p.center.dy - e.center.dy;
      if (dx.abs() > dy.abs()) {
        return dx > 0 ? Dir.right : Dir.left;
      } else {
        return dy > 0 ? Dir.down : Dir.up;
      }
    }
    const opts = [Dir.down, Dir.down, Dir.left, Dir.right, Dir.up];
    return opts[_rng.nextInt(opts.length)];
  }

  // ---- 子弹 ----
  void _updateBullets(double dt) {
    for (final b in bullets) {
      if (b.dead) continue;
      b.pos = b.pos + b.dir.vector * b.speed * dt;
      final r = b.rect;

      if (r.left < 0 || r.top < 0 || r.right > kBattle || r.bottom > kBattle) {
        b.dead = true;
        explosions.add(Explosion(b.center, life: 0.18, size: kCell));
        continue;
      }
      if (baseAlive && r.overlaps(baseRect)) {
        baseAlive = false;
        _terrainVersion++;
        b.dead = true;
        explosions.add(
            Explosion(baseRect.center, life: 0.5, size: kTank * 2, big: true));
        _sound.play('big_explosion');
        HapticFeedback.heavyImpact();
        phase = Phase.gameOver;
        _sound.play('gameover');
        continue;
      }
      bool hitWall = false;
      bool hitSteel = false;
      final x0 = worldToCell(r.left);
      final x1 = worldToCell(r.right - 0.001);
      final y0 = worldToCell(r.top);
      final y1 = worldToCell(r.bottom - 0.001);
      for (int y = y0; y <= y1 && !hitWall; y++) {
        for (int x = x0; x <= x1 && !hitWall; x++) {
          final t = grid[y][x];
          if (t == Terrain.brick) {
            grid[y][x] = Terrain.empty;
            _terrainVersion++;
            hitWall = true;
          } else if (t == Terrain.steel) {
            if (b.power >= 3) {
              grid[y][x] = Terrain.empty;
              _terrainVersion++;
            }
            hitWall = true;
            hitSteel = true;
          }
        }
      }
      if (hitWall) {
        b.dead = true;
        explosions.add(Explosion(b.center, life: 0.18, size: kCell));
        _sound.play(hitSteel ? 'steel' : 'hit', volume: 0.25);
        continue;
      }
      if (b.fromPlayer) {
        for (final e in enemies) {
          if (e.alive && !e.spawning && e.rect.overlaps(r)) {
            _hitEnemy(e);
            b.dead = true;
            break;
          }
        }
      } else {
        for (final p in players) {
          if (p.alive && p.rect.overlaps(r)) {
            _hitPlayer(p);
            b.dead = true;
            break;
          }
        }
      }
    }

    for (int i = 0; i < bullets.length; i++) {
      final a = bullets[i];
      if (a.dead) continue;
      for (int j = i + 1; j < bullets.length; j++) {
        final o = bullets[j];
        if (o.dead || a.fromPlayer == o.fromPlayer) continue;
        if (a.rect.overlaps(o.rect)) {
          a.dead = true;
          o.dead = true;
          explosions.add(Explosion(a.center, life: 0.16, size: kCell));
          break;
        }
      }
    }

    bullets.removeWhere((b) => b.dead);
  }

  void _hitEnemy(Tank e) {
    if (e.kind == EnemyKind.armor) {
      e.armorHp--;
      if (e.armorHp > 0) {
        explosions.add(Explosion(e.center, life: 0.14, size: kCell));
        _sound.play('hit', volume: 0.3);
        return;
      }
    }
    e.alive = false;
    _killed++;
    score += scoreForKind(e.kind!);
    explosions.add(Explosion(e.center, life: 0.4, size: kTank * 1.4, big: true));
    _sound.play('explosion', volume: 0.5);
    HapticFeedback.mediumImpact();
    if (e.bonus) _spawnPowerUp();
  }

  void _hitPlayer(Tank p) {
    if (p.shieldTime > 0) {
      explosions.add(Explosion(p.center, life: 0.14, size: kCell));
      return;
    }
    p.alive = false;
    explosions.add(Explosion(p.center, life: 0.5, size: kTank * 1.6, big: true));
    _sound.play('big_explosion');
    HapticFeedback.heavyImpact();
    if (lives > 0) {
      lives--;
      Future.delayed(const Duration(milliseconds: 700), () => _respawnPlayer(p));
    } else {
      // 无剩余生命：该玩家不再重生；全部阵亡则结束
      if (players.every((q) => !q.alive)) {
        phase = Phase.gameOver;
        _sound.play('gameover');
      }
    }
  }

  void _respawnPlayer(Tank p) {
    if (phase != Phase.playing) return;
    final col = p.player == 0 ? kPlayerSpawnCol : kPlayer2SpawnCol;
    p.pos = Offset(cellToWorld(col), cellToWorld(kPlayerSpawnRow));
    p.dir = Dir.up;
    p.alive = true;
    p.shieldTime = kPlayerShieldStart;
    p.fireCooldown = 0; // 保留火力等级，合作体验更友好
  }

  void _checkProgress() {
    if (_spawned >= _queue.length && enemies.isEmpty) {
      _levelClearStartScore = score;
      _levelClearBonus = _computeLevelBonus();
      score += _levelClearBonus;
      phase = Phase.levelClear;
      _levelClearTimer = kLevelClearDuration;
      _sound.play('powerup');
    }
  }

  int _computeLevelBonus() {
    int b = 1000; // 通关基础奖励
    if (baseAlive) b += 500; // 基地完好
    b += (lives > 0 ? lives : 0) * 200; // 剩余生命
    return b;
  }

  // ---- 道具 ----
  void _spawnPowerUp() {
    for (int attempts = 0; attempts < 40; attempts++) {
      final cx = _rng.nextInt(kCells - 3) + 1;
      final cy = _rng.nextInt(kCells - 5) + 1;
      final pos = Offset(cellToWorld(cx), cellToWorld(cy));
      final r = Rect.fromLTWH(pos.dx, pos.dy, kTank, kTank);
      bool blocked = false;
      final x0 = worldToCell(r.left), x1 = worldToCell(r.right - 0.001);
      final y0 = worldToCell(r.top), y1 = worldToCell(r.bottom - 0.001);
      for (int y = y0; y <= y1 && !blocked; y++) {
        for (int x = x0; x <= x1 && !blocked; x++) {
          if (grid[y][x] == Terrain.steel || grid[y][x] == Terrain.water) {
            blocked = true;
          }
        }
      }
      if (blocked) continue;
      if (r.overlaps(baseRect)) continue;
      final kind = PowerKind.values[_rng.nextInt(PowerKind.values.length)];
      powerups.add(PowerUp(kind, pos));
      break;
    }
  }

  void _applyPowerUp(Tank p, PowerKind k) {
    switch (k) {
      case PowerKind.star:
        if (p.bulletLevel < 3) p.bulletLevel++;
        score += 500;
        break;
      case PowerKind.helmet:
        p.shieldTime = max(p.shieldTime, kHelmetTime);
        break;
      case PowerKind.grenade:
        for (final e in enemies.toList()) {
          if (e.alive && !e.spawning) _hitEnemy(e);
        }
        break;
      case PowerKind.tank:
        lives++;
        score += 500;
        break;
      case PowerKind.clock:
        _freezeTime = kFreezeTime;
        break;
      case PowerKind.shovel:
        _shovelTime = kShovelTime;
        applyBaseArmor(true);
        break;
    }
    score += 200;
    _sound.play('powerup');
    HapticFeedback.mediumImpact();
  }

  // ---- 暂停 / 静音 ----
  void _togglePause() {
    if (phase == Phase.playing) {
      phase = Phase.paused;
    } else if (phase == Phase.paused) {
      phase = Phase.playing;
    }
  }

  void _toggleMute() {
    _sound.muted = !_sound.muted;
    setState(() {});
  }

  void _onPrimaryTap() {
    switch (phase) {
      case Phase.paused:
        phase = Phase.playing;
        break;
      case Phase.gameOver:
      case Phase.victory:
        phase = Phase.start;
        loadLevel(0, twoPlayer: false);
        break;
      case Phase.start:
      case Phase.playing:
      case Phase.levelClear:
        break;
    }
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent e) {
    if (e is! KeyDownEvent) {
      return _isGameKey(e.logicalKey) ? KeyEventResult.handled : KeyEventResult.ignored;
    }
    final k = e.logicalKey;
    if (k == LogicalKeyboardKey.keyP || k == LogicalKeyboardKey.escape) {
      _togglePause();
      return KeyEventResult.handled;
    } else if (k == LogicalKeyboardKey.keyM) {
      _toggleMute();
      return KeyEventResult.handled;
    } else if (k == LogicalKeyboardKey.enter || k == LogicalKeyboardKey.numpadEnter) {
      if (phase == Phase.start) {
        startGame(twoPlayer: false);
      } else if (phase == Phase.gameOver || phase == Phase.victory) {
        phase = Phase.start;
        loadLevel(0, twoPlayer: false);
      }
      return KeyEventResult.handled;
    }
    if (_isGameKey(k)) return KeyEventResult.handled;
    return KeyEventResult.ignored;
  }

  bool _isGameKey(LogicalKeyboardKey k) {
    return k == LogicalKeyboardKey.arrowUp ||
        k == LogicalKeyboardKey.arrowDown ||
        k == LogicalKeyboardKey.arrowLeft ||
        k == LogicalKeyboardKey.arrowRight ||
        k == LogicalKeyboardKey.space ||
        k == LogicalKeyboardKey.keyW ||
        k == LogicalKeyboardKey.keyA ||
        k == LogicalKeyboardKey.keyS ||
        k == LogicalKeyboardKey.keyD ||
        k == LogicalKeyboardKey.keyJ;
  }

  // ---- 界面 ----
  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: phase == Phase.start ||
          phase == Phase.gameOver ||
          phase == Phase.victory,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && (phase == Phase.playing || phase == Phase.paused)) {
          _togglePause();
        }
      },
      child: Scaffold(
        backgroundColor: const Color(0xFF0E0E0E),
        body: SafeArea(
          child: Focus(
            focusNode: _focus,
            autofocus: true,
            onKeyEvent: _onKey,
            child: LayoutBuilder(
              builder: (ctx, c) {
                final w = c.maxWidth;
                final h = c.maxHeight;
                final battle = min(c.maxWidth, c.maxHeight);
                return Stack(
                  fit: StackFit.expand,
                  children: [
                    // 战场：铺满宽度并居中（静态地形层 + 动态实体层）
                    Center(
                      child: SizedBox(
                        width: battle,
                        height: battle,
                        child: Stack(
                          fit: StackFit.expand,
                          children: [
                            RepaintBoundary(
                              child: CustomPaint(
                                size: Size.square(battle),
                                painter: TerrainPainter(
                                  grid: grid,
                                  baseAlive: baseAlive,
                                  terrainVersion: _terrainVersion,
                                ),
                              ),
                            ),
                            CustomPaint(
                              size: Size.square(battle),
                              painter: EntitiesPainter(
                                grid: grid,
                                players: players,
                                enemies: enemies,
                                bullets: bullets,
                                explosions: explosions,
                                powerups: powerups,
                                time: _time,
                                freezeActive: _freezeTime > 0,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                    Positioned(left: 0, right: 0, top: 0, child: _buildHud()),
                    if (phase == Phase.playing) ..._buildControls(w, h),
                    if (phase != Phase.playing)
                      Positioned.fill(child: _buildOverlay()),
                  ],
                );
              },
            ),
          ),
        ),
      ),
    );
  }

  List<Widget> _buildControls(double w, double h) {
    if (_twoPlayer) {
      // 双人对角镜像：P1 摇杆左上 / 开火左下；P2 摇杆右下 / 开火右上。
      // 两位玩家分坐左右、面对面时，各自控件位置正好与对方相反、且都符合"左手摇杆、右手开火"。
      return [
        Positioned(
          left: 0,
          top: 56,
          width: w * 0.5,
          bottom: h * 0.5,
          child: _Joystick(onDir: (d) => setState(() => _dir1 = d)),
        ),
        Positioned(left: 14, bottom: 18, child: _buildFireButton(0)),
        Positioned(
          left: w * 0.5,
          top: h * 0.5,
          width: w * 0.5,
          bottom: 0,
          child: _Joystick(onDir: (d) => setState(() => _dir2 = d)),
        ),
        Positioned(right: 14, top: 60, child: _buildFireButton(1)),
      ];
    }
    return [
      Positioned(
        left: 0,
        top: 56,
        width: w * 0.56,
        bottom: 0,
        child: _Joystick(onDir: (d) => setState(() => _dir1 = d)),
      ),
      Positioned(right: 22, bottom: 28, child: _buildFireButton(0)),
    ];
  }

  // ---- HUD ----
  Widget _buildHud() {
    final remaining = _queue.isEmpty ? 0 : (_queue.length - _killed);
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 6, 8, 6),
      decoration: const BoxDecoration(
        color: Color(0x66000000),
        border: Border(bottom: BorderSide(color: Color(0xFF333333))),
      ),
      child: Row(
        children: [
          _hudChip('关卡', '${level + 1}'),
          const SizedBox(width: 10),
          _hudChip('得分', '$score'),
          const SizedBox(width: 8),
          _playerStars(0),
          if (_twoPlayer) _playerStars(1),
          const Spacer(),
          _livesIndicator(),
          const SizedBox(width: 8),
          _enemyCounter(remaining),
          const SizedBox(width: 6),
          _iconButton(
            _sound.muted ? Icons.volume_off : Icons.volume_up,
            _toggleMute,
          ),
          const SizedBox(width: 2),
          _iconButton(
            phase == Phase.paused ? Icons.play_arrow : Icons.pause,
            _togglePause,
          ),
        ],
      ),
    );
  }

  Widget _hudChip(String label, String value) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(label,
            style: const TextStyle(color: Color(0xFF888888), fontSize: 9)),
        Text(value,
            style: const TextStyle(
                color: Color(0xFFFFD54A),
                fontWeight: FontWeight.bold,
                fontSize: 13,
                fontFamily: 'monospace')),
      ],
    );
  }

  Widget _playerStars(int p) {
    final t = p < players.length ? players[p] : null;
    final lvl = t?.bulletLevel ?? 0;
    final color = p == 0
        ? const Color(0xFFFFD54A)
        : const Color(0xFF6EE060);
    return Padding(
      padding: const EdgeInsets.only(left: 6),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text('P${p + 1}',
              style: TextStyle(
                  color: color, fontSize: 8, fontWeight: FontWeight.bold)),
          for (int i = 0; i < 3; i++)
            Icon(Icons.star,
                size: 10, color: i < lvl ? color : const Color(0xFF444444)),
        ],
      ),
    );
  }

  Widget _livesIndicator() {
    final n = lives < 0 ? 0 : lives;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        const Icon(Icons.favorite, color: Color(0xFFFF5252), size: 14),
        const SizedBox(width: 3),
        Text('×$n',
            style: const TextStyle(
                color: Color(0xFFFF8A80),
                fontWeight: FontWeight.bold,
                fontFamily: 'monospace',
                fontSize: 13)),
      ],
    );
  }

  Widget _enemyCounter(int remaining) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        const Icon(Icons.flag, color: Color(0xFF90CAF9), size: 14),
        const SizedBox(width: 3),
        Text('$remaining',
            style: const TextStyle(
                color: Color(0xFF90CAF9),
                fontWeight: FontWeight.bold,
                fontFamily: 'monospace',
                fontSize: 13)),
      ],
    );
  }

  Widget _iconButton(IconData icon, VoidCallback onTap) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.all(6),
        child: Icon(icon, color: const Color(0xFFCCCCCC), size: 20),
      ),
    );
  }

  // ---- 开火按钮 ----
  Widget _buildFireButton(int player) {
    final held = player == 0 ? _fire1 : _fire2;
    final isP1 = player == 0;
    final base = isP1 ? const Color(0xCCE04A2D) : const Color(0xCC2E8B57);
    final hot = isP1 ? const Color(0xCCFF8A65) : const Color(0xCC66DE52);
    final border = isP1 ? const Color(0xFFFFAB91) : const Color(0xFFA5D6A7);
    final sz = _twoPlayer ? 72.0 : 86.0;
    return _HoldButton(
      onDown: () => setState(() {
        if (isP1) {
          _fire1 = true;
        } else {
          _fire2 = true;
        }
      }),
      onUp: () => setState(() {
        if (isP1) {
          _fire1 = false;
        } else {
          _fire2 = false;
        }
      }),
      child: Container(
        width: sz,
        height: sz,
        decoration: BoxDecoration(
          color: held ? hot : base,
          shape: BoxShape.circle,
          border: Border.all(color: border, width: 2),
          boxShadow: const [
            BoxShadow(
                color: Color(0x55000000), blurRadius: 8, offset: Offset(0, 3))
          ],
        ),
        alignment: Alignment.center,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('开火',
                style: TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.bold,
                    fontSize: 15,
                    fontFamily: 'monospace',
                    decoration: TextDecoration.none)),
            Text('P${player + 1}',
                style: TextStyle(
                    color: border,
                    fontSize: 9,
                    fontWeight: FontWeight.bold,
                    fontFamily: 'monospace',
                    decoration: TextDecoration.none)),
          ],
        ),
      ),
    );
  }

  // ---- 覆盖层 ----
  Widget _buildOverlay() {
    if (phase == Phase.start) return _buildStartMenu();
    if (phase == Phase.levelClear) return _buildLevelClear();
    if (phase == Phase.paused) return _buildPausePanel();
    // gameOver / victory
    String title;
    String subtitle = '';
    String action = '';
    Color color;
    switch (phase) {
      case Phase.gameOver:
        title = '游戏结束';
        subtitle = '最终得分：$score';
        action = '点击屏幕重新开始';
        color = const Color(0xFFFF5252);
        break;
      case Phase.victory:
        title = '全境通关！';
        subtitle = '最终得分：$score';
        action = '点击屏幕再来一次';
        color = const Color(0xFFFFD54A);
        break;
      default:
        return const SizedBox.shrink();
    }
    final isWin = phase == Phase.victory;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: _onPrimaryTap,
      child: Container(
        color: const Color(0xCC000000),
        alignment: Alignment.center,
        padding: const EdgeInsets.symmetric(horizontal: 24),
        child: Stack(
          alignment: Alignment.center,
          children: [
            if (isWin)
              Positioned.fill(child: CustomPaint(painter: _SparklePainter(_time))),
            Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(title,
                    style: TextStyle(
                        color: color,
                        fontSize: 32,
                        fontWeight: FontWeight.bold,
                        fontFamily: 'monospace',
                        letterSpacing: 2,
                        shadows: const [
                          Shadow(color: Color(0xAA000000), blurRadius: 8)
                        ],
                        decoration: TextDecoration.none)),
                if (subtitle.isNotEmpty) ...[
                  const SizedBox(height: 14),
                  Text(subtitle,
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                          color: Color(0xFFDDDDDD),
                          fontSize: 13,
                          fontFamily: 'monospace',
                          decoration: TextDecoration.none)),
                ],
                if (action.isNotEmpty) ...[
                  const SizedBox(height: 20),
                  Text(action,
                      style: TextStyle(
                          color: color,
                          fontSize: 13,
                          fontFamily: 'monospace',
                          decoration: TextDecoration.none)),
                ],
              ],
            ),
          ],
        ),
      ),
    );
  }

  // ---- 暂停面板（含退出） ----
  Widget _buildPausePanel() {
    return Container(
      color: const Color(0xCC000000),
      alignment: Alignment.center,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Text('暂停',
              style: TextStyle(
                  color: Colors.white,
                  fontSize: 30,
                  fontWeight: FontWeight.bold,
                  fontFamily: 'monospace',
                  decoration: TextDecoration.none)),
          const SizedBox(height: 26),
          _overlayButton('继续游戏', Icons.play_arrow, () {
            phase = Phase.playing;
            setState(() {});
          }),
          const SizedBox(height: 12),
          _overlayButton('退出到主菜单', Icons.home, () {
            phase = Phase.start;
            loadLevel(0, twoPlayer: false);
            setState(() {});
          }),
        ],
      ),
    );
  }

  Widget _overlayButton(String label, IconData icon, VoidCallback onTap) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Container(
        width: 210,
        padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 18),
        decoration: BoxDecoration(
          color: const Color(0xFF1C1C1C),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: const Color(0xFF888888), width: 1.2),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, color: const Color(0xFFDDDDDD), size: 20),
            const SizedBox(width: 10),
            Text(label,
                style: const TextStyle(
                    color: Colors.white,
                    fontSize: 15,
                    fontFamily: 'monospace',
                    decoration: TextDecoration.none)),
          ],
        ),
      ),
    );
  }

  // ---- 开始菜单 ----
  Widget _buildStartMenu() {
    return Container(
      color: const Color(0xCC000000),
      alignment: Alignment.center,
      padding: const EdgeInsets.symmetric(horizontal: 28),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Text('坦克大战',
              style: TextStyle(
                  color: Color(0xFFFFD54A),
                  fontSize: 36,
                  fontWeight: FontWeight.bold,
                  fontFamily: 'monospace',
                  letterSpacing: 4,
                  shadows: [
                    Shadow(color: Color(0x88FFD54A), blurRadius: 16),
                  ],
                  decoration: TextDecoration.none)),
          const SizedBox(height: 6),
          const Text('TANK · BATTLE',
              style: TextStyle(
                  color: Color(0xFF888888),
                  fontSize: 10,
                  letterSpacing: 6,
                  decoration: TextDecoration.none)),
          const SizedBox(height: 30),
          _menuButton('单人模式', '1 PLAYER', false, const Color(0xFFE0A030)),
          const SizedBox(height: 14),
          _menuButton('双人合作', '2 PLAYER CO-OP', true, const Color(0xFF4CAF50)),
          const SizedBox(height: 24),
          const Text(
              '左半屏拖动移动 · 右下开火（按下即射、按住连发）\n'
              '双人：P1 左半屏 / P2 右半屏，各自摇杆 + 开火',
              textAlign: TextAlign.center,
              style: TextStyle(
                  color: Color(0xFF999999),
                  fontSize: 11,
                  height: 1.6,
                  decoration: TextDecoration.none)),
        ],
      ),
    );
  }

  Widget _menuButton(String label, String sub, bool twoPlayer, Color color) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => startGame(twoPlayer: twoPlayer),
      child: Container(
        width: 230,
        padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 20),
        decoration: BoxDecoration(
          color: const Color(0xFF1C1C1C),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: color, width: 1.5),
          boxShadow: const [
            BoxShadow(color: Color(0x44000000), blurRadius: 6, offset: Offset(0, 2))
          ],
        ),
        child: Column(
          children: [
            Text(label,
                style: TextStyle(
                    color: color,
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                    decoration: TextDecoration.none)),
            const SizedBox(height: 2),
            Text(sub,
                style: const TextStyle(
                    color: Color(0xFF888888),
                    fontSize: 9,
                    letterSpacing: 2,
                    decoration: TextDecoration.none)),
          ],
        ),
      ),
    );
  }

  // ---- 过关炫酷结算 ----
  Widget _buildLevelClear() {
    final p = (1 - (_levelClearTimer / kLevelClearDuration)).clamp(0.0, 1.0);
    final titleT = (p / 0.25).clamp(0.0, 1.0);
    final scale = _easeOutBack(titleT); // 0 -> ~1（带回弹）
    final countT = (p / 0.6).clamp(0.0, 1.0);
    final shown = (_levelClearStartScore + _levelClearBonus * _easeOutCubic(countT))
        .round();
    final nextOp = ((p - 0.7) / 0.2).clamp(0.0, 1.0);

    return Container(
      decoration: const BoxDecoration(
        gradient: RadialGradient(
          center: Alignment.center,
          radius: 0.85,
          colors: [Color(0xFF3A2E00), Color(0xDD000000)],
        ),
      ),
      child: Stack(
        children: [
          Positioned.fill(child: CustomPaint(painter: _SparklePainter(_time))),
          Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Opacity(
                  opacity: titleT,
                  child: Text('STAGE ${level + 1} CLEAR',
                      style: const TextStyle(
                          color: Color(0xFFAAAAAA),
                          fontSize: 11,
                          letterSpacing: 6,
                          decoration: TextDecoration.none)),
                ),
                const SizedBox(height: 8),
                Transform.scale(
                  scale: 0.6 + scale * 0.4,
                  child: const Text('过关！',
                      style: TextStyle(
                          color: Color(0xFFFFD54A),
                          fontSize: 44,
                          fontWeight: FontWeight.bold,
                          fontFamily: 'monospace',
                          letterSpacing: 4,
                          shadows: [
                            Shadow(color: Color(0xCCFFD54A), blurRadius: 20)
                          ],
                          decoration: TextDecoration.none)),
                ),
                const SizedBox(height: 22),
                _rewardLine('关卡奖励', '+1000', p, 0.14),
                if (baseAlive) _rewardLine('基地完好', '+500', p, 0.26),
                if (lives > 0)
                  _rewardLine('剩余生命 ×$lives', '+${lives * 200}', p, 0.38),
                const SizedBox(height: 18),
                const Text('当前得分',
                    style: TextStyle(
                        color: Color(0xFF888888),
                        fontSize: 10,
                        decoration: TextDecoration.none)),
                const SizedBox(height: 2),
                Text('$shown',
                    style: const TextStyle(
                        color: Color(0xFFFFE082),
                        fontSize: 30,
                        fontWeight: FontWeight.bold,
                        fontFamily: 'monospace',
                        decoration: TextDecoration.none)),
                const SizedBox(height: 24),
                Opacity(
                  opacity: nextOp,
                  child: Text('进入关卡 ${level + 2}  ▶',
                      style: const TextStyle(
                          color: Color(0xFFA3E635),
                          fontSize: 13,
                          fontFamily: 'monospace',
                          decoration: TextDecoration.none)),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _rewardLine(String label, String value, double p, double at) {
    final op = ((p - at) / 0.18).clamp(0.0, 1.0);
    final off = (1 - op) * 18.0;
    return Opacity(
      opacity: op,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 3),
        child: Transform.translate(
          offset: Offset(off, 0),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(label,
                  style: const TextStyle(
                      color: Color(0xFFCCCCCC),
                      fontSize: 12,
                      decoration: TextDecoration.none)),
              const SizedBox(width: 12),
              Text(value,
                  style: const TextStyle(
                      color: Color(0xFFFFD54A),
                      fontSize: 13,
                      fontWeight: FontWeight.bold,
                      fontFamily: 'monospace',
                      decoration: TextDecoration.none)),
            ],
          ),
        ),
      ),
    );
  }

  double _easeOutBack(double t) {
    const c1 = 1.70158;
    const c3 = c1 + 1;
    final x = t - 1;
    return (1 + c3 * pow(x, 3) + c1 * pow(x, 2)).toDouble();
  }

  double _easeOutCubic(double t) => (1 - pow(1 - t, 3)).toDouble();
}

/// 动态虚拟摇杆：在区域内按下即出现，拖动控制 4 向，松开消失。
class _Joystick extends StatefulWidget {
  final ValueChanged<Dir?> onDir;
  const _Joystick({required this.onDir});

  @override
  State<_Joystick> createState() => _JoystickState();
}

class _JoystickState extends State<_Joystick> {
  static const double _base = 66;
  static const double _dead = 14;

  Offset? _origin;
  Offset? _knob;

  void _update(Offset o, {required bool isNew}) {
    final origin = isNew ? o : (_origin ?? o);
    final dx = o.dx - origin.dx;
    final dy = o.dy - origin.dy;
    final len2 = dx * dx + dy * dy;
    Dir? dir;
    Offset knob = origin;
    if (len2 >= _dead * _dead) {
      final len = sqrt(len2);
      final cl = len > _base ? _base / len : 1.0;
      knob = Offset(origin.dx + dx * cl, origin.dy + dy * cl);
      if (dx.abs() > dy.abs()) {
        dir = dx > 0 ? Dir.right : Dir.left;
      } else {
        dir = dy > 0 ? Dir.down : Dir.up;
      }
    }
    setState(() {
      _origin = origin;
      _knob = knob;
    });
    widget.onDir(dir);
  }

  void _reset() {
    setState(() {
      _origin = null;
      _knob = null;
    });
    widget.onDir(null);
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      onPanDown: (d) => _update(d.localPosition, isNew: true),
      onPanUpdate: (d) => _update(d.localPosition, isNew: false),
      onPanEnd: (_) => _reset(),
      onPanCancel: _reset,
      child: CustomPaint(
        painter: _JoystickPainter(_origin, _knob),
        child: const SizedBox.expand(),
      ),
    );
  }
}

class _JoystickPainter extends CustomPainter {
  final Offset? origin;
  final Offset? knob;
  _JoystickPainter(this.origin, this.knob);

  @override
  void paint(Canvas canvas, Size size) {
    if (origin == null) return;
    canvas.drawCircle(origin!, 66, Paint()..color = const Color(0x22FFFFFF));
    canvas.drawCircle(
      origin!,
      66,
      Paint()
        ..color = const Color(0x66FFFFFF)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2,
    );
    canvas.drawCircle(knob ?? origin!, 26, Paint()..color = const Color(0xCCFFFFFF));
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => true;
}

/// 过关/胜利界面的闪烁火花背景
class _SparklePainter extends CustomPainter {
  final double t;
  _SparklePainter(this.t);

  static const List<List<double>> _sparks = [
    [0.12, 0.18], [0.85, 0.22], [0.20, 0.80], [0.80, 0.78],
    [0.50, 0.12], [0.08, 0.50], [0.92, 0.50], [0.30, 0.30],
    [0.70, 0.32], [0.28, 0.66], [0.72, 0.64], [0.45, 0.86],
    [0.55, 0.86], [0.15, 0.35], [0.86, 0.66], [0.40, 0.20],
  ];

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..strokeWidth = 1.6
      ..strokeCap = StrokeCap.round;
    for (int i = 0; i < _sparks.length; i++) {
      final tw = 0.5 + 0.5 * sin(t * 4 + i * 1.3);
      final cx = _sparks[i][0] * size.width;
      final cy = _sparks[i][1] * size.height;
      final r = 3 + tw * 6;
      final col = Color.lerp(
              const Color(0xFFFFE082), const Color(0xFFFFFFFF), tw)!;
      paint.color = col.withValues(alpha: 0.25 + tw * 0.7);
      canvas.drawLine(Offset(cx - r, cy), Offset(cx + r, cy), paint);
      canvas.drawLine(Offset(cx, cy - r), Offset(cx, cy + r), paint);
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => true;
}

/// 按住式按钮
class _HoldButton extends StatefulWidget {
  final Widget child;
  final VoidCallback onDown;
  final VoidCallback onUp;

  const _HoldButton({
    required this.child,
    required this.onDown,
    required this.onUp,
  });

  @override
  State<_HoldButton> createState() => _HoldButtonState();
}

class _HoldButtonState extends State<_HoldButton> {
  bool _held = false;

  void _set(bool v) {
    if (_held == v) return;
    _held = v;
    if (v) {
      widget.onDown();
    } else {
      widget.onUp();
    }
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTapDown: (_) => _set(true),
      onTapUp: (_) => _set(false),
      onTapCancel: () => _set(false),
      child: widget.child,
    );
  }
}
