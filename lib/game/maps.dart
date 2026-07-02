// 关卡地图与敌人编成
// 地图按 13x13 的"整砖"设计，每个字符 = 1 整砖(=2x2 半格)。
// 字符: 空格/. = 空, B = 砖, S = 钢, W = 水, T = 树, I = 冰
// 基地与出生点由游戏逻辑在解析后覆盖，因此地图里可不画。

import 'dart:math';

import 'constants.dart';

class LevelMap {
  final String name;
  final List<String> tiles; // 13 行，每行约 13 字符

  const LevelMap(this.name, this.tiles);
}

const int kTileCount = 13;

final List<LevelMap> kLevels = [
  LevelMap('关卡 1 · 初阵', [
    '             ',
    ' B B B B B B ',
    ' B B B B B B ',
    '             ',
    ' BBBB   BBBB ',
    '      S      ',
    ' T T T T T T ',
    '      W      ',
    ' BBBB   BBBB ',
    '             ',
    ' B B B B B B ',
    ' B B B B B B ',
    '             ',
  ]),
  LevelMap('关卡 2 · 十字阵', [
    '      S      ',
    '  BBB B BBB  ',
    '  B       B  ',
    'BB B  W W  B ',
    'B    W   W  B',
    'BB B  W W  B ',
    '  B   T   B  ',
    'BB B  W W  B ',
    'B    W   W  B',
    'BB B  W W  B ',
    '  B       B  ',
    '  BBB B BBB  ',
    '      S      ',
  ]),
  LevelMap('关卡 3 · 迷宫', [
    'B B B B B B B',
    'B S B B B S B',
    'B B B W W B B',
    'B B  W   W  B',
    'B B W T T W B',
    'B   W T T W  ',
    'B B W T T W B',
    'B   W T T W  ',
    'B B W T T W B',
    'B B  W   W  B',
    'B B B W W B B',
    'B S B B B S B',
    'B B B B B B B',
  ]),
  LevelMap('关卡 4 · 水乡', [
    ' W W W W W W ',
    '             ',
    'B B B S B B B',
    'B B B S B B B',
    '  WWW S WWW  ',
    ' T T T   T T ',
    '  WWW   WWW  ',
    'B B B S B B B',
    'B B B S B B B',
    '             ',
    ' W W W W W W ',
    ' B B B B B B ',
    '             ',
  ]),
  LevelMap('关卡 5 · 钢铁堡垒', [
    'S S S B S S S',
    'S B B B B B S',
    'S B W W W B S',
    'B B W T W B B',
    'B B W T W B B',
    'B B B T B B B',
    'B B W T W B B',
    'B B W T W B B',
    'S B W W W B S',
    'S B B B B B S',
    'S S S B S S S',
    ' B B B B B B ',
    '             ',
  ]),
];

/// 把整砖地图解析为 26x26 半格地形
List<List<Terrain>> parseTerrain(LevelMap map) {
  final grid = List.generate(
    kCells,
    (_) => List<Terrain>.filled(kCells, Terrain.empty),
  );
  for (int row = 0; row < kTileCount; row++) {
    final line = row < map.tiles.length ? map.tiles[row] : '';
    for (int col = 0; col < kTileCount; col++) {
      final ch = col < line.length ? line[col] : ' ';
      final t = _charToTerrain(ch);
      for (int dy = 0; dy < 2; dy++) {
        for (int dx = 0; dx < 2; dx++) {
          grid[row * 2 + dy][col * 2 + dx] = t;
        }
      }
    }
  }
  return grid;
}

Terrain _charToTerrain(String ch) {
  switch (ch) {
    case 'B':
    case 'b':
      return Terrain.brick;
    case 'S':
    case 's':
      return Terrain.steel;
    case 'W':
    case 'w':
      return Terrain.water;
    case 'T':
    case 't':
      return Terrain.trees;
    case 'I':
    case 'i':
      return Terrain.ice;
    default:
      return Terrain.empty;
  }
}

/// 根据关卡生成 20 个敌人的种类队列（难度随关卡递增）
List<EnemyKind> enemyQueueForLevel(int level, Random rng) {
  final basic = max(4, 14 - level * 2);
  final fast = level >= 2 ? 3 + level : 2;
  final power = level >= 2 ? 2 + (level ~/ 2) : 1;
  final armor = level >= 3 ? 2 + (level - 2) : 1;

  final list = <EnemyKind>[];
  void add(EnemyKind k, int n) {
    for (int i = 0; i < n; i++) {
      list.add(k);
    }
  }

  add(EnemyKind.basic, basic);
  add(EnemyKind.fast, fast);
  add(EnemyKind.power, power);
  add(EnemyKind.armor, armor);
  // 补足 / 截断到固定数量
  while (list.length < kEnemiesPerLevel) {
    list.add(EnemyKind.basic);
  }
  if (list.length > kEnemiesPerLevel) {
    list.removeRange(kEnemiesPerLevel, list.length);
  }
  list.shuffle(rng);
  return list;
}

/// 标记队列中哪几个是"闪烁奖励坦克"（击毁后掉落道具）
Set<int> bonusIndices(List<EnemyKind> queue) {
  return {
    queue.length ~/ 4,
    (queue.length * 3) ~/ 4,
  };
}

/// 击毁得分
int scoreForKind(EnemyKind k) {
  switch (k) {
    case EnemyKind.basic:
      return 100;
    case EnemyKind.fast:
      return 200;
    case EnemyKind.power:
      return 300;
    case EnemyKind.armor:
      return 400;
  }
}
