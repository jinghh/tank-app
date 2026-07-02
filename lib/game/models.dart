// 游戏实体：坦克、子弹、爆炸、道具

import 'dart:ui';

import 'constants.dart';

class Tank {
  /// 左上角世界坐标
  Offset pos;
  Dir dir;
  final bool isPlayer;
  final EnemyKind? kind;
  double speed;
  final int player; // 玩家编号：0=P1，1=P2（敌人忽略）

  bool alive = true;
  double fireCooldown = 0;
  double shieldTime = 0; // 无敌（开局/头盔）
  int bulletLevel = 0; // 玩家火力等级 0..3
  bool bonus = false; // 敌人：击毁掉落道具
  int armorHp = 1; // 装甲敌人血量
  double aiTimer = 0;
  Dir aiDir;
  bool spawning = true; // 出生动画
  double spawnAnim = 0;

  Tank({
    required this.pos,
    required this.dir,
    required this.isPlayer,
    this.kind,
    required this.speed,
    this.bonus = false,
    this.player = 0,
  }) : aiDir = dir {
    if (kind == EnemyKind.armor) armorHp = 4;
    if (isPlayer) shieldTime = kPlayerShieldStart;
  }

  Rect get rect => Rect.fromLTWH(pos.dx, pos.dy, kTank, kTank);
  Offset get center => Offset(pos.dx + kTank / 2, pos.dy + kTank / 2);
}

class Bullet {
  Offset pos;
  Dir dir;
  final bool fromPlayer;
  final int? owner; // 玩家子弹所属玩家编号（0/1），敌方子弹为 null
  double speed;
  bool dead = false;
  final int power; // >=3 可破钢

  Bullet({
    required this.pos,
    required this.dir,
    required this.fromPlayer,
    required this.speed,
    this.power = 0,
    this.owner,
  });

  Rect get rect => Rect.fromLTWH(pos.dx, pos.dy, kBullet, kBullet);
  Offset get center => Offset(pos.dx + kBullet / 2, pos.dy + kBullet / 2);
}

class Explosion {
  Offset pos;
  double t = 0; // 已存在时间
  final double life;
  final double size;
  bool big;

  Explosion(this.pos, {this.life = 0.32, this.size = kTank, this.big = false});

  bool get done => t >= life;
}

class PowerUp {
  PowerKind kind;
  final Offset pos; // 左上角
  double life = kPowerupLife;
  PowerUp(this.kind, this.pos);
  Rect get rect => Rect.fromLTWH(pos.dx, pos.dy, kTank, kTank);
}
