// 经典坦克大战 - Flutter 复刻版
// 方向键 / WASD 移动，空格开火，P 暂停；移动端使用屏幕方向键与开火键。

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'game/battle_city_game.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  // 纯移动端：锁定竖屏，保证战场正方形铺满屏幕宽度
  SystemChrome.setPreferredOrientations(<DeviceOrientation>[
    DeviceOrientation.portraitUp,
  ]);
  runApp(const TankApp());
}

class TankApp extends StatelessWidget {
  const TankApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: '坦克大战',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        scaffoldBackgroundColor: const Color(0xFF1A1A1A),
        fontFamily: 'monospace',
      ),
      home: const Scaffold(
        backgroundColor: Color(0xFF1A1A1A),
        body: BattleCityGame(),
      ),
    );
  }
}
