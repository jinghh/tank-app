// 战场渲染器：以 208x208 世界坐标绘制，由外层按方形整体缩放。
// 性能要点：
//   1) Paint 全部复用（顶层 final），杜绝每帧数千次分配；
//   2) 静态地形由 TerrainPainter 单独绘制，仅在地形变化时重绘（shouldRepaint 比对版本号）；
//   3) 动态实体由 EntitiesPainter 每帧重绘。

import 'dart:math' as math;

import 'package:flutter/rendering.dart';

import 'constants.dart';
import 'models.dart';

// ---- 复用 Paint（避免每帧分配，性能关键）----
final Paint _pBg = Paint()..color = const Color(0xFF000000);
final Paint _pIce = Paint()..color = const Color(0xFFCFE8FF);
final Paint _pBrick = Paint()..color = const Color(0xFFC2682E);
final Paint _pBrickDark = Paint()..color = const Color(0xFF6E3414)
  ..strokeWidth = 0.8;
final Paint _pSteel = Paint()..color = const Color(0xFF8A93A6);
final Paint _pSteelStroke = Paint()
  ..color = const Color(0xFFC7CEDB)
  ..style = PaintingStyle.stroke
  ..strokeWidth = 1;
final Paint _pSteelHi = Paint()..color = const Color(0xFFE8ECF4);
final Paint _pWater = Paint()..color = const Color(0xFF1F4F8F);
final Paint _pWaterWave = Paint()
  ..color = const Color(0xFF8FC4F2)
  ..style = PaintingStyle.stroke
  ..strokeWidth = 1;
final Paint _pTree = Paint()..color = const Color(0xFF2E7D32);
final Paint _pTreeDot = Paint()..color = const Color(0xFF66BB6A);
final Paint _pBulletCore = Paint()..color = const Color(0xFFFFFFFF);
final Paint _pBulletP = Paint()..color = const Color(0xFFFFE082);
final Paint _pBulletE = Paint()..color = const Color(0xFFFFCC80);
// 坦克：车身/炮塔颜色按坦克设置（单线程顺序绘制，可安全复用）
final Paint _pTrack = Paint()..color = const Color(0xFF33372B);
final Paint _pTrackHi = Paint()..color = const Color(0xFF1C1E16);
final Paint _pBody = Paint();
final Paint _pOutline = Paint()
  ..color = const Color(0xFF2A2A2A)
  ..style = PaintingStyle.stroke
  ..strokeWidth = 0.8;
final Paint _pTurret = Paint();
final Paint _pHatch = Paint()..color = const Color(0xFF2A2A2A);
final Paint _pShieldA = Paint()
  ..color = const Color(0xCCFFFFFF)
  ..style = PaintingStyle.stroke
  ..strokeWidth = 1.4;
final Paint _pShieldB = Paint()
  ..color = const Color(0x88ADD8E6)
  ..style = PaintingStyle.stroke
  ..strokeWidth = 1.4;
final Paint _pFreeze = Paint()..color = const Color(0x6680DEEA);
final Paint _pSpawnOn = Paint()..color = const Color(0xFF8FBC2F);
final Paint _pSpawnOff = Paint()..color = const Color(0xFFFFFFFF);
final Paint _pExpSpark = Paint()
  ..color = const Color(0xFFFFFFFF)
  ..strokeWidth = 1.5;
final List<Paint> _pExpRings = [Paint(), Paint(), Paint(), Paint()];
final Paint _pPuBox = Paint()..color = const Color(0xFFFFD600);
final Paint _pPuBorder = Paint()
  ..color = const Color(0xFF000000)
  ..style = PaintingStyle.stroke
  ..strokeWidth = 1;
final Paint _pPuSym = Paint()..color = const Color(0xFF1A1A1A);
final Paint _pPuClock = Paint()
  ..color = const Color(0xFF1A1A1A)
  ..style = PaintingStyle.stroke
  ..strokeWidth = 1.4;

const List<Color> _expColors = <Color>[
  Color(0xFFFFFFFF),
  Color(0xFFFFEB3B),
  Color(0xFFFF9800),
  Color(0xFFE53935),
];

Color _playerBodyColor(int p) =>
    p == 0 ? const Color(0xFFFFD54A) : const Color(0xFF6EE060);

Color _tankBodyColor(Tank t, bool flash) {
  if (flash) return const Color(0xFFFF3B3B);
  if (t.isPlayer) return _playerBodyColor(t.player);
  switch (t.kind) {
    case EnemyKind.basic:
      return const Color(0xFFB0B6BF);
    case EnemyKind.fast:
      return const Color(0xFF67E8F9);
    case EnemyKind.power:
      return const Color(0xFFA3E635);
    case EnemyKind.armor:
      switch (t.armorHp) {
        case 4:
          return const Color(0xFFE2E8F0);
        case 3:
          return const Color(0xFFFCA5A5);
        case 2:
          return const Color(0xFFF87171);
        default:
          return const Color(0xFFDC2626);
      }
    case null:
      return const Color(0xFFB0B6BF);
  }
}

// ============================ 静态地形层 ============================
class TerrainPainter extends CustomPainter {
  final List<List<Terrain>> grid;
  final bool baseAlive;
  final int terrainVersion;

  TerrainPainter({
    required this.grid,
    required this.baseAlive,
    required this.terrainVersion,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final scale = size.shortestSide / kBattle;
    canvas.save();
    canvas.scale(scale);
    canvas.drawRect(Rect.fromLTWH(0, 0, kBattle, kBattle), _pBg);

    for (int y = 0; y < kCells; y++) {
      for (int x = 0; x < kCells; x++) {
        final r = Rect.fromLTWH(x * kCell, y * kCell, kCell, kCell);
        switch (grid[y][x]) {
          case Terrain.ice:
            canvas.drawRect(r, _pIce);
            break;
          case Terrain.water:
            _drawWater(canvas, r);
            break;
          case Terrain.brick:
            _drawBrick(canvas, r);
            break;
          case Terrain.steel:
            _drawSteel(canvas, r);
            break;
          case Terrain.trees:
          case Terrain.empty:
            break;
        }
      }
    }
    _drawBase(canvas, baseAlive);
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant TerrainPainter old) =>
      old.terrainVersion != terrainVersion;
}

// ============================ 动态实体层 ============================
class EntitiesPainter extends CustomPainter {
  final List<List<Terrain>> grid;
  final List<Tank> players;
  final List<Tank> enemies;
  final List<Bullet> bullets;
  final List<Explosion> explosions;
  final List<PowerUp> powerups;
  final double time;
  final bool freezeActive;

  EntitiesPainter({
    required this.grid,
    required this.players,
    required this.enemies,
    required this.bullets,
    required this.explosions,
    required this.powerups,
    required this.time,
    required this.freezeActive,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final scale = size.shortestSide / kBattle;
    canvas.save();
    canvas.scale(scale);

    // 敌方坦克 / 子弹 / 爆炸
    for (final e in enemies) {
      _drawTank(canvas, e, time, freezeActive);
    }
    for (final b in bullets) {
      _drawBullet(canvas, b);
    }
    for (final ex in explosions) {
      _drawExplosion(canvas, ex);
    }

    // 树丛覆盖（敌方坦克可借草丛隐身）
    for (int y = 0; y < kCells; y++) {
      for (int x = 0; x < kCells; x++) {
        if (grid[y][x] == Terrain.trees) {
          _drawTrees(canvas, Rect.fromLTWH(x * kCell, y * kCell, kCell, kCell));
        }
      }
    }

    // 玩家坦克始终绘制于草丛之上（永远看得到自己）
    for (final p in players) {
      _drawTank(canvas, p, time, freezeActive);
    }

    // 道具
    for (final pu in powerups) {
      _drawPowerUp(canvas, pu, time);
    }

    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => true;
}

// ============================ 绘制子程序 ============================
void _drawBrick(Canvas c, Rect r) {
  c.drawRect(r, _pBrickDark);
  final half = r.height / 2;
  for (int i = 0; i < 2; i++) {
    final row = Rect.fromLTWH(r.left, r.top + i * half, r.width, half);
    c.drawRect(row.deflate(0.6), _pBrick);
    final off = (i == 0) ? r.width / 2 : 0.0;
    c.drawLine(
      Offset(row.left + off, row.top),
      Offset(row.left + off, row.bottom),
      _pBrickDark,
    );
  }
}

void _drawSteel(Canvas c, Rect r) {
  c.drawRect(r, _pSteel);
  c.drawRect(r.deflate(0.5), _pSteelStroke);
  c.drawRect(Rect.fromLTWH(r.left + 1, r.top + 1, 2, 2), _pSteelHi);
}

void _drawWater(Canvas c, Rect r) {
  c.drawRect(r, _pWater);
  // 静态波纹（地形层缓存，不随时间动画）
  const phase = 1.5;
  c.drawLine(Offset(r.left + phase, r.top + 3.0), Offset(r.left + phase + 3.0, r.top + 3.0), _pWaterWave);
  c.drawLine(Offset(r.left + phase, r.top + 6.0), Offset(r.left + phase + 3.0, r.top + 6.0), _pWaterWave);
}

void _drawTrees(Canvas c, Rect r) {
  c.drawRect(r, _pTree);
  c.drawRect(Rect.fromLTWH(r.left + 1, r.top + 1, 2, 2), _pTreeDot);
  c.drawRect(Rect.fromLTWH(r.left + 5, r.top + 2, 2, 2), _pTreeDot);
  c.drawRect(Rect.fromLTWH(r.left + 2, r.top + 5, 2, 2), _pTreeDot);
  c.drawRect(Rect.fromLTWH(r.left + 5, r.top + 5, 2, 2), _pTreeDot);
}

void _drawBase(Canvas c, bool alive) {
  final r = Rect.fromLTWH(
    cellToWorld(kBaseCol),
    cellToWorld(kBaseRow),
    kCell * 2,
    kCell * 2,
  );
  if (!alive) {
    c.drawRect(r, Paint()..color = const Color(0xFF4A4A4A));
    final dk = Paint()..color = const Color(0xFF2A2A2A);
    c.drawRect(Rect.fromLTWH(r.left + 2, r.top + 2, 5, 5), dk);
    c.drawRect(Rect.fromLTWH(r.left + 8, r.top + 4, 5, 5), dk);
    c.drawRect(Rect.fromLTWH(r.left + 4, r.top + 9, 6, 4), dk);
    return;
  }
  final gold = Paint()..color = const Color(0xFFE0B020);
  final dark = Paint()..color = const Color(0xFF8A6A10);
  c.drawRect(Rect.fromLTWH(r.center.dx - 3, r.top + 6, 6, 7), gold);
  c.drawRect(Rect.fromLTWH(r.center.dx - 2, r.top + 3, 4, 4), gold);
  c.drawRect(Rect.fromLTWH(r.left + 2, r.top + 7, 3, 5), gold);
  c.drawRect(Rect.fromLTWH(r.right - 5, r.top + 7, 3, 5), gold);
  c.drawRect(Rect.fromLTWH(r.center.dx - 1, r.top + 6, 2, 1), dark);
  c.drawRect(Rect.fromLTWH(r.center.dx, r.top + 4, 1, 1), dark);
}

void _drawTank(Canvas c, Tank t, double time, bool freezeActive) {
  if (!t.alive) return;
  final center = t.center;

  if (!t.isPlayer && t.spawning) {
    _drawSpawnStar(c, center, t.spawnAnim);
    return;
  }

  final flash = t.bonus && (time * 4).floor() % 2 == 0;
  final bodyColor = _tankBodyColor(t, flash);
  _pBody.color = bodyColor;
  _pTurret.color = Color.lerp(bodyColor, const Color(0xFF000000), 0.25)!;

  c.save();
  c.translate(center.dx, center.dy);
  c.rotate(t.dir.radians);

  // 履带
  c.drawRect(Rect.fromLTWH(-8, -7, 3, 14), _pTrack);
  c.drawRect(Rect.fromLTWH(5, -7, 3, 14), _pTrack);
  for (double i = -6; i <= 5; i += 3) {
    c.drawRect(Rect.fromLTWH(-8, i, 3, 1.4), _pTrackHi);
    c.drawRect(Rect.fromLTWH(5, i, 3, 1.4), _pTrackHi);
  }
  // 车身
  c.drawRect(Rect.fromLTWH(-5, -5, 10, 10), _pBody);
  c.drawRect(Rect.fromLTWH(-5, -5, 10, 10), _pOutline);
  // 炮塔
  c.drawCircle(Offset.zero, 3.2, _pTurret);
  c.drawRect(Rect.fromLTWH(-1, -8, 2, 5), _pTurret);
  c.drawRect(Rect.fromLTWH(-1.5, -1, 3, 2), _pHatch);

  c.restore();

  if (t.shieldTime > 0) {
    _drawShield(c, center, time);
  }
  if (freezeActive && !t.isPlayer) {
    c.drawCircle(center, kTank * 0.6, _pFreeze);
  }
}

void _drawShield(Canvas c, Offset center, double time) {
  final on = (time * 8).floor() % 2 == 0;
  final r = kTank / 2 + 2;
  final path = Path();
  for (int i = 0; i < 8; i++) {
    final a = i * math.pi / 4;
    final p = Offset(center.dx + r * math.cos(a), center.dy + r * math.sin(a));
    if (i == 0) {
      path.moveTo(p.dx, p.dy);
    } else {
      path.lineTo(p.dx, p.dy);
    }
  }
  path.close();
  c.drawPath(path, on ? _pShieldA : _pShieldB);
}

void _drawSpawnStar(Canvas c, Offset center, double anim) {
  final s = 5.0 + (anim * 6).clamp(0.0, 4.0);
  final rot = anim * 6;
  final on = (anim * 10).floor() % 2 == 0;
  final path = Path();
  for (int i = 0; i < 8; i++) {
    final rr = (i.isEven) ? s : s * 0.4;
    final a = rot + i * math.pi / 4;
    final p = Offset(center.dx + rr * math.cos(a), center.dy + rr * math.sin(a));
    if (i == 0) {
      path.moveTo(p.dx, p.dy);
    } else {
      path.lineTo(p.dx, p.dy);
    }
  }
  path.close();
  c.drawPath(path, on ? _pSpawnOn : _pSpawnOff);
}

void _drawBullet(Canvas c, Bullet b) {
  final r = b.rect;
  c.drawRect(r, _pBulletCore);
  c.drawRect(r.deflate(1), b.fromPlayer ? _pBulletP : _pBulletE);
}

void _drawExplosion(Canvas c, Explosion ex) {
  final p = (ex.t / ex.life).clamp(0.0, 1.0);
  final grow = ex.big ? 1.0 : 0.7;
  final radius = ex.size * (0.3 + p * 0.9) * grow;
  final alpha = (1 - p).clamp(0.0, 1.0);

  for (int i = 0; i < _expColors.length; i++) {
    final f = i / _expColors.length;
    _pExpRings[i].color = _expColors[i].withValues(alpha: alpha * (0.9 - f * 0.2));
    c.drawCircle(ex.pos, radius * (1 - f * 0.7), _pExpRings[i]);
  }
  if (p < 0.5) {
    _pExpSpark.color = const Color(0xFFFFFFFF).withValues(alpha: alpha);
    final d = radius * 1.2;
    c.drawLine(Offset(ex.pos.dx - d, ex.pos.dy), Offset(ex.pos.dx + d, ex.pos.dy), _pExpSpark);
    c.drawLine(Offset(ex.pos.dx, ex.pos.dy - d), Offset(ex.pos.dx, ex.pos.dy + d), _pExpSpark);
  }
}

void _drawPowerUp(Canvas c, PowerUp p, double time) {
  final blink = (time * 4).floor() % 2 == 0;
  if (!blink && p.life < 3) return;
  final r = p.rect;
  c.drawRect(r, _pPuBox);
  c.drawRect(r.deflate(1), _pPuBorder);
  final cx = r.center.dx;
  final cy = r.center.dy;
  switch (p.kind) {
    case PowerKind.star:
      _star(c, r.center, 5, _pPuSym);
      break;
    case PowerKind.helmet:
      c.drawRect(Rect.fromLTWH(cx - 4, cy - 3, 8, 5), _pPuSym);
      c.drawRect(Rect.fromLTWH(cx - 4, cy + 1, 8, 2), _pPuSym);
      break;
    case PowerKind.grenade:
      c.drawCircle(Offset(cx, cy + 1), 4, _pPuSym);
      c.drawRect(Rect.fromLTWH(cx - 1, cy - 5, 2, 2), _pPuSym);
      break;
    case PowerKind.tank:
      c.drawRect(Rect.fromLTWH(cx - 4, cy - 2, 8, 5), _pPuSym);
      c.drawRect(Rect.fromLTWH(cx - 1, cy - 5, 2, 3), _pPuSym);
      break;
    case PowerKind.clock:
      c.drawCircle(Offset(cx, cy), 4, _pPuClock);
      _pPuSym.strokeWidth = 1.2;
      c.drawLine(Offset(cx, cy), Offset(cx, cy - 3), _pPuSym);
      c.drawLine(Offset(cx, cy), Offset(cx + 3, cy), _pPuSym);
      break;
    case PowerKind.shovel:
      c.drawRect(Rect.fromLTWH(cx - 3, cy + 1, 6, 3), _pPuSym);
      c.drawRect(Rect.fromLTWH(cx - 1, cy - 4, 2, 5), _pPuSym);
      break;
  }
}

void _star(Canvas c, Offset center, double r, Paint p) {
  final path = Path();
  for (int i = 0; i < 10; i++) {
    final rr = (i.isEven) ? r : r * 0.45;
    final a = -math.pi / 2 + i * math.pi / 5;
    final pt = Offset(center.dx + rr * math.cos(a), center.dy + rr * math.sin(a));
    if (i == 0) {
      path.moveTo(pt.dx, pt.dy);
    } else {
      path.lineTo(pt.dx, pt.dy);
    }
  }
  path.close();
  c.drawPath(path, p);
}
