// 生成坦克大战应用图标。
// 运行：dart run tool/gen_icon.dart
// 输出：assets/icon.png（带背景，1024）、assets/icon_fg.png（透明前景，用于自适应图标）

import 'dart:io';
import 'package:image/image.dart';

const int S = 1024;

void main() {
  // 1) 完整图标：深色渐变背景 + 坦克
  final full = Image(width: S, height: S);
  drawBackground(full);
  drawTank(full, S * 0.11, S * 0.13, S * 0.78);
  File('assets/icon.png').writeAsBytesSync(encodePng(full));

  // 2) 自适应图标前景：透明背景 + 坦克（居中，留出安全区）
  final fg = Image(width: S, height: S);
  fill(fg, color: ColorUint8.rgba(0, 0, 0, 0));
  drawTank(fg, S * 0.20, S * 0.20, S * 0.60);
  File('assets/icon_fg.png').writeAsBytesSync(encodePng(fg));

  print('Generated assets/icon.png and assets/icon_fg.png');
}

int lerp(int a, int b, double t) => (a + (b - a) * t).round();

void drawBackground(Image img) {
  // 垂直渐变：钢蓝灰 #54657A -> #34414E（中明度，使深色履带/轮子可见）
  const top = [0x54, 0x65, 0x7A];
  const bot = [0x34, 0x41, 0x4E];
  for (int y = 0; y < S; y++) {
    final t = y / S;
    drawLine(img,
        x1: 0,
        y1: y,
        x2: S - 1,
        y2: y,
        color: ColorUint8.rgb(
            lerp(top[0], bot[0], t), lerp(top[1], bot[1], t), lerp(top[2], bot[2], t)));
  }
  // 细网格点缀（战场感）
  for (int x = 0; x < S; x += 64) {
    drawLine(img,
        x1: x, y1: 0, x2: x, y2: S, color: ColorUint8.rgba(255, 255, 255, 8));
  }
}

void drawTank(Image img, double ox, double oy, double sz) {
  Color c(int r, int g, int b) => ColorUint8.rgb(r, g, b);
  final yellow = c(255, 213, 74);
  final yellowHi = c(255, 224, 130);
  final turret = c(199, 154, 46);
  final dark = c(43, 43, 43);
  final darker = c(24, 24, 24);
  final black = c(10, 10, 10);

  void box(double x, double y, double w, double h, Color col) {
    fillRect(img,
        x1: (ox + x * sz).round(),
        y1: (oy + y * sz).round(),
        x2: (ox + (x + w) * sz).round(),
        y2: (oy + (y + h) * sz).round(),
        color: col);
  }

  // 履带
  box(0.06, 0.18, 0.20, 0.70, dark);
  box(0.74, 0.18, 0.20, 0.70, dark);
  for (double yy = 0.22; yy < 0.85; yy += 0.12) {
    box(0.06, yy, 0.20, 0.05, darker);
    box(0.74, yy, 0.20, 0.05, darker);
  }
  // 车身阴影 + 主体
  box(0.24, 0.22, 0.52, 0.66, black);
  box(0.26, 0.24, 0.48, 0.62, yellow);
  // 高光
  box(0.28, 0.26, 0.44, 0.06, yellowHi);
  // 炮塔
  fillRect(img,
      x1: (ox + 0.34 * sz).round(),
      y1: (oy + 0.34 * sz).round(),
      x2: (ox + 0.66 * sz).round(),
      y2: (oy + 0.66 * sz).round(),
      color: turret);
  fillCircle(img,
      x: (ox + 0.50 * sz).round(),
      y: (oy + 0.50 * sz).round(),
      radius: (0.13 * sz).round(),
      color: black);
  // 炮管（朝上）
  box(0.46, 0.02, 0.08, 0.40, turret);
  box(0.46, 0.02, 0.08, 0.06, yellowHi);
}
