// 简单冒烟测试：确保游戏根控件可正常构建并显示开始界面。

import 'package:flutter_test/flutter_test.dart';

import 'package:tank_app/main.dart';

void main() {
  testWidgets('TankApp shows start screen', (WidgetTester tester) async {
    await tester.pumpWidget(const TankApp());
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 16));
    expect(find.text('坦克大战'), findsOneWidget);
  });
}
