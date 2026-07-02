// 坦克大战 - 纯移动端交互版
// 控制：左半屏拖动 = 虚拟摇杆（4 向移动）；右下按钮 = 开火（按下即时发射，按住连发）。

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
  Tank? player;
  final List<Tank> enemies = [];
  final List<Bullet> bullets = [];
  final List<Explosion> explosions = [];
  final List<PowerUp> powerups = [];

  // ---- 状态 ----
  Phase phase = Phase.start;
  int level = 0;
  int score = 0;
  int lives = kStartLives;
  bool baseAlive = true;

  late List<EnemyKind> _queue;
  late Set<int> _bonusSet;
  int _spawned = 0;
  int _killed = 0;
  int _spawnCursor = 0;
  double _spawnTimer = 0;
  double _levelClearTimer = 0;

  double _freezeTime = 0;
  double _shovelTime = 0;
  double _time = 0;

  final Random _rng = Random();
  final FocusNode _focus = FocusNode();
  final SoundService _sound = SoundService();

  Dir? _touchDir;
  bool _touchFire = false;

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
    loadLevel(0);
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
  void loadLevel(int n) {
    level = n;
    final map = kLevels[n % kLevels.length];
    grid = parseTerrain(map);
    enemies.clear();
    bullets.clear();
    explosions.clear();
    powerups.clear();
    _freezeTime = 0;
    _shovelTime = 0;
    baseAlive = true;

    _clearArea(kPlayerSpawnCol, kPlayerSpawnRow);
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

    player = Tank(
      pos: Offset(cellToWorld(kPlayerSpawnCol), cellToWorld(kPlayerSpawnRow)),
      dir: Dir.up,
      isPlayer: true,
      speed: kPlayerSpeed,
    );
  }

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
  }

  void startGame() {
    score = 0;
    lives = kStartLives;
    loadLevel(0);
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
    if (mounted) setState(() {});
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

    final p = player!;
    if (p.alive) {
      p.shieldTime = max(0, p.shieldTime - dt);

      final dir = _effectiveDir();
      if (dir != null) {
        _tryMoveTank(p, dir, p.speed * dt);
      }
      // 开火：按下即时发射，无冷却；仅以"场上玩家子弹数"为上限，按住即连发。
      if (_effectiveFire()) {
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
      if (p.alive && p.rect.overlaps(pu.rect)) {
        _applyPowerUp(pu.kind);
        pu.life = -1;
      }
    }
    powerups.removeWhere((pu) => pu.life <= 0);

    // 移除本帧被击毁的敌方坦克，避免"幽灵坦克"：不可见却仍能移动/开火/伤害玩家
    enemies.removeWhere((e) => !e.alive);

    _checkProgress();
  }

  // ---- 输入汇总 ----
  Dir? _effectiveDir() {
    final kb = _keyboardDir();
    if (kb != null) return kb;
    return _touchDir;
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

  bool _effectiveFire() {
    final kb = HardwareKeyboard.instance;
    return _touchFire ||
        kb.logicalKeysPressed.contains(LogicalKeyboardKey.space) ||
        kb.logicalKeysPressed.contains(LogicalKeyboardKey.keyJ);
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
    if (self.isPlayer) {
      for (final e in enemies) {
        if (e.alive && !e.spawning && e.rect.overlaps(r)) return true;
      }
    } else {
      if (player != null && player!.alive && player!.rect.overlaps(r)) return true;
    }
    return false;
  }

  // ---- 开火 ----
  void _fire(Tank t) {
    final tip = t.center + t.dir.vector * (kTank / 2);
    final bp = tip - const Offset(kBullet / 2, kBullet / 2);
    if (t.isPlayer) {
      final active = bullets.where((b) => b.fromPlayer && !b.dead).length;
      final maxB = t.bulletLevel >= 2 ? 2 : 1;
      if (active >= maxB) return; // 场上子弹数已达上限，等当前的飞完
      final fast = t.bulletLevel >= 1;
      bullets.add(Bullet(
        pos: bp,
        dir: t.dir,
        fromPlayer: true,
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
    if (player != null && player!.rect.overlaps(rect)) blocked = true;
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
    if (!e.alive) return; // 已击毁：本帧起不再行动（update 末尾会统一移除）
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

  Dir _pickEnemyDir(Tank e) {
    final p = player;
    if (p != null && p.alive && _rng.nextDouble() < 0.5) {
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
            hitWall = true;
          } else if (t == Terrain.steel) {
            if (b.power >= 3) grid[y][x] = Terrain.empty;
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
        final p = player;
        if (p != null && p.alive && p.rect.overlaps(r)) {
          _hitPlayer();
          b.dead = true;
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

  void _hitPlayer() {
    final p = player!;
    if (p.shieldTime > 0) {
      explosions.add(Explosion(p.center, life: 0.14, size: kCell));
      return;
    }
    p.alive = false;
    explosions.add(Explosion(p.center, life: 0.5, size: kTank * 1.6, big: true));
    _sound.play('big_explosion');
    HapticFeedback.heavyImpact();
    lives--;
    if (lives < 0) {
      phase = Phase.gameOver;
      _sound.play('gameover');
    } else {
      Future.delayed(const Duration(milliseconds: 700), _respawnPlayer);
    }
  }

  void _respawnPlayer() {
    if (phase != Phase.playing) return;
    final p = player!;
    p.pos = Offset(cellToWorld(kPlayerSpawnCol), cellToWorld(kPlayerSpawnRow));
    p.dir = Dir.up;
    p.alive = true;
    p.shieldTime = kPlayerShieldStart;
    p.bulletLevel = 0;
    p.fireCooldown = 0;
  }

  void _checkProgress() {
    if (_spawned >= _queue.length && enemies.isEmpty) {
      phase = Phase.levelClear;
      _levelClearTimer = 2.6;
      _sound.play('powerup');
    }
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

  void _applyPowerUp(PowerKind k) {
    final p = player!;
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
      case Phase.start:
        startGame();
        break;
      case Phase.paused:
        phase = Phase.playing;
        break;
      case Phase.gameOver:
      case Phase.victory:
        phase = Phase.start;
        loadLevel(0);
        break;
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
        startGame();
      } else if (phase == Phase.gameOver || phase == Phase.victory) {
        phase = Phase.start;
        loadLevel(0);
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
        if (!didPop &&
            (phase == Phase.playing || phase == Phase.paused)) {
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
                // 战场为正方形：取屏幕短边，竖屏下即占满宽度并垂直居中
                final battle = min(c.maxWidth, c.maxHeight);
                return Stack(
                  fit: StackFit.expand,
                  children: [
                    // 战场：按短边缩放为正方形，铺满宽度并居中
                    Positioned.fill(
                      child: GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onTap: _onPrimaryTap,
                        child: Center(
                          child: CustomPaint(
                            size: Size.square(battle),
                            painter: BattlePainter(
                              grid: grid,
                              player: player,
                              enemies: enemies,
                              bullets: bullets,
                              explosions: explosions,
                              powerups: powerups,
                              baseAlive: baseAlive,
                              time: _time,
                              freezeActive: _freezeTime > 0,
                            ),
                          ),
                        ),
                      ),
                    ),
                    // 顶部 HUD（含暂停 / 静音）
                    Positioned(left: 0, right: 0, top: 0, child: _buildHud()),
                    // 虚拟摇杆：左半屏拖动控制方向
                    if (phase == Phase.playing)
                      Positioned(
                        left: 0,
                        top: 56,
                        width: w * 0.56,
                        bottom: 0,
                        child: _Joystick(onDir: (d) => setState(() => _touchDir = d)),
                      ),
                    // 开火按钮：右下，按下即时发射
                    if (phase == Phase.playing)
                      Positioned(
                        right: 22,
                        bottom: 28,
                        child: _buildFireButton(),
                      ),
                    // 菜单覆盖层（自身可点击：开始 / 继续 / 重开）
                    if (phase != Phase.playing)
                      Positioned.fill(
                        child: GestureDetector(
                          behavior: HitTestBehavior.opaque,
                          onTap: _onPrimaryTap,
                          child: _buildOverlay(),
                        ),
                      ),
                  ],
                );
              },
            ),
          ),
        ),
      ),
    );
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
          _fireStars(),
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

  Widget _fireStars() {
    final lvl = player?.bulletLevel ?? 0;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (int i = 0; i < 3; i++)
          Icon(
            Icons.star,
            size: 12,
            color: i < lvl ? const Color(0xFFFFD54A) : const Color(0xFF444444),
          ),
      ],
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
  Widget _buildFireButton() {
    return _HoldButton(
      onDown: () => setState(() => _touchFire = true),
      onUp: () => setState(() => _touchFire = false),
      child: Container(
        width: 86,
        height: 86,
        decoration: BoxDecoration(
          color: _touchFire ? const Color(0xCCFF8A65) : const Color(0xCCE04A2D),
          shape: BoxShape.circle,
          border: Border.all(color: const Color(0xFFFFAB91), width: 2),
          boxShadow: const [
            BoxShadow(
                color: Color(0x55000000), blurRadius: 8, offset: Offset(0, 3))
          ],
        ),
        alignment: Alignment.center,
        child: const Text('开火',
            style: TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.bold,
                fontSize: 16,
                fontFamily: 'monospace',
                decoration: TextDecoration.none)),
      ),
    );
  }

  // ---- 菜单覆盖层 ----
  Widget _buildOverlay() {
    String title;
    String? subtitle;
    String action = '';
    Color color;
    switch (phase) {
      case Phase.start:
        title = '坦克大战';
        subtitle = '保护基地 · 消灭全部敌军\n\n'
            '左侧屏幕拖动 → 移动\n'
            '右下按钮 → 开火（即时连发）';
        action = '点击屏幕开始';
        color = const Color(0xFFFFD54A);
        break;
      case Phase.paused:
        title = '暂停';
        action = '点击屏幕继续';
        color = const Color(0xFFFFFFFF);
        break;
      case Phase.levelClear:
        title = '过关！';
        subtitle = '进入关卡 ${level + 2}';
        color = const Color(0xFFA3E635);
        break;
      case Phase.gameOver:
        title = '游戏结束';
        subtitle = '最终得分：$score';
        action = '点击屏幕重新开始';
        color = const Color(0xFFFF5252);
        break;
      case Phase.victory:
        title = '胜利！';
        subtitle = '通关全部关卡\n最终得分：$score';
        action = '点击屏幕再来一次';
        color = const Color(0xFFFFD54A);
        break;
      case Phase.playing:
        return const SizedBox.shrink();
    }
    return Container(
      color: const Color(0xCC000000),
      alignment: Alignment.center,
      padding: const EdgeInsets.symmetric(horizontal: 24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(title,
              style: TextStyle(
                  color: color,
                  fontSize: 30,
                  fontWeight: FontWeight.bold,
                  fontFamily: 'monospace',
                  letterSpacing: 2,
                  decoration: TextDecoration.none)),
          if (subtitle != null) ...[
            const SizedBox(height: 14),
            Text(subtitle,
                textAlign: TextAlign.center,
                style: const TextStyle(
                    color: Color(0xFFDDDDDD),
                    fontSize: 12,
                    height: 1.6,
                    fontFamily: 'monospace',
                    decoration: TextDecoration.none)),
          ],
          if (action.isNotEmpty) ...[
            const SizedBox(height: 18),
            Text(action,
                style: TextStyle(
                    color: color,
                    fontSize: 13,
                    fontFamily: 'monospace',
                    decoration: TextDecoration.none)),
          ],
        ],
      ),
    );
  }
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
    canvas.drawCircle(
      origin!,
      66,
      Paint()..color = const Color(0x22FFFFFF),
    );
    canvas.drawCircle(
      origin!,
      66,
      Paint()
        ..color = const Color(0x66FFFFFF)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2,
    );
    canvas.drawCircle(
      knob ?? origin!,
      26,
      Paint()..color = const Color(0xCCFFFFFF),
    );
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
