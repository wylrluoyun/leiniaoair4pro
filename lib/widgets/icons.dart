import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

/// ---------------------------------------------------------------------------
/// 线性图标
///
/// 设计稿的图标是 24×24 网格、1.35px 描边、圆角端点的细线风格。
/// Material 图标是实心/圆润风格，与这套界面不搭，所以路径直接取自设计稿的
/// SVG `d` 属性。dart:ui 没有 SVG 路径解析，这里带一个够用的小解析器
/// （M/L/H/V/C/S/Q/T/A/Z），保证与设计稿逐像素一致。
/// ---------------------------------------------------------------------------

Path _svg(String d) => SvgPathParser.parse(d);

Path _rr(double l, double t, double w, double h, double r) => Path()
  ..addRRect(
    RRect.fromRectAndRadius(Rect.fromLTWH(l, t, w, h), Radius.circular(r)),
  );

Path _c(double cx, double cy, double r) =>
    Path()..addOval(Rect.fromCircle(center: Offset(cx, cy), radius: r));

class Ico {
  const Ico(this.stroke, [this.fill]);

  final List<Path> Function() stroke;
  final List<Path> Function()? fill;
}

/// 眼镜（品牌图标 / 概览页底栏）
final icoGlasses = Ico(() => [
      _rr(2.5, 7.5, 8, 6, 3),
      _rr(13.5, 7.5, 8, 6, 3),
      _svg('M10.5 10.5h3'),
    ]);

/// 画面（外接屏）
final icoDisplay = Ico(
  () => [_rr(2.5, 5, 19, 13, 2.5)],
  () => [_c(8, 9.5, .9), _c(16, 9.5, .9)],
);

/// 姿态（同心圆 + 十字刻度）
final icoPose = Ico(() => [
      _c(12, 12, 8.5),
      _c(12, 12, 2.2),
      _svg('M12 3.5v3M12 17.5v3M3.5 12h3M17.5 12h3'),
    ]);

/// 系统（双滑杆）
final icoSystem = Ico(() => [
      _svg('M4 8h9M17.5 8H20M4 16h2.5M11 16h9'),
      _c(15, 8, 2.4),
      _c(8.5, 16, 2.4),
    ]);

/// 眼睛（状态卡 glyph）
final icoEye = Ico(() => [
      _svg('M2 12s3.6-6.5 10-6.5S22 12 22 12s-3.6 6.5-10 6.5S2 12 2 12z'),
      _c(12, 12, 2.6),
    ]);

/// 空画面框（空间预览里的虚拟屏）
final icoCast = Ico(() => [
      _svg('M3 8V5.5A2.5 2.5 0 0 1 5.5 3H8M16 3h2.5A2.5 2.5 0 0 1 21 5.5V8'
          'M21 16v2.5a2.5 2.5 0 0 1-2.5 2.5H16M8 21H5.5A2.5 2.5 0 0 1 3 18.5V16'),
    ]);

/// 画面复位
final icoRecenter = Ico(() => [
      _c(12, 12, 5.5),
      _svg('M12 2.5v3M12 18.5v3M2.5 12h3M18.5 12h3'),
    ]);

/// 触控板（手）
final icoTouchpad = Ico(() => [
      _svg('M9 12.5V6a1.8 1.8 0 1 1 3.6 0v6'),
      _svg('M12.6 12.2V9.6a1.7 1.7 0 1 1 3.4 0v2.6'),
      _svg('M16 12v-.8a1.7 1.7 0 1 1 3.4 0v4.3A6.5 6.5 0 0 1 12.9 22H11'
          'a4.5 4.5 0 0 1-3.6-1.7L4.8 16.9a1.7 1.7 0 0 1 2.6-2.2L9 16.6'),
    ]);

/// 信息圆
final icoInfo = Ico(
  () => [_c(12, 12, 9), _svg('M12 11v5')],
  () => [_c(12, 8.1, .85)],
);

/// 截图（相机）：机身 + 取景凸起，镜头用实心圆
final icoShot = Ico(
  () => [
        _rr(3, 7, 18, 12.5, 2.5),
        _svg('M8.6 7l1.2-2.2h4.4L15.4 7'),
      ],
  () => [_c(12, 13.2, 3.2)],
);

/// 录像（红点）：外圈 + 实心圆
final icoRecord = Ico(
  () => [_c(12, 12, 8.5)],
  () => [_c(12, 12, 4.2)],
);

/// 文件夹（打开截图目录）
final icoFolder = Ico(() => [
      _svg('M3 7.5A2.5 2.5 0 0 1 5.5 5h3.2l1.8 2.2h8A2.5 2.5 0 0 1 21 9.7v7.8'
          'A2.5 2.5 0 0 1 18.5 20h-13A2.5 2.5 0 0 1 3 17.5z'),
    ]);

/// 盾牌（权限申请）
final icoShield = Ico(() => [
      _svg('M12 3l7 2.6v5.6c0 4.4-2.9 7.8-7 9.2-4.1-1.4-7-4.8-7-9.2V5.6z'),
      _svg('M8.8 12.1l2.2 2.2 4.2-4.4'),
    ]);

/// 结束进程（叉在圆里）
final icoKill = Ico(() => [
      _c(12, 12, 8.5),
      _svg('M9 9l6 6M15 9l-6 6'),
    ]);

/// 无障碍（人形）
final icoA11y = Ico(() => [
      _c(12, 4.5, 2),
      _svg('M4 9.5l8 1.5 8-1.5M12 11v4l-3 6M12 15l3 6'),
    ]);

/// 终端（Shizuku）
final icoTerm = Ico(() => [
      _rr(3, 4, 18, 16, 2.5),
      _svg('M7.5 9.5l3 2.5-3 2.5M13 15h4'),
    ]);

final icoChevron = Ico(() => [_svg('M9.5 6l6 6-6 6')]);
final icoBack = Ico(() => [_svg('M15 5l-7 7 7 7')]);
final icoReturn = Ico(() => [_svg('M9 5L4 10l5 5M4 10h9a7 7 0 0 1 0 14')]);
final icoMoon = Ico(() => [_svg('M20 14.5A8.5 8.5 0 0 1 9.5 4a8.5 8.5 0 1 0 10.5 10.5z')]);
final icoStop = Ico(() => [_rr(7, 7, 10, 10, 1.5)]);
final icoExpand = Ico(() => [
      _svg('M4 9V5.5A1.5 1.5 0 0 1 5.5 4H9M15 4h3.5A1.5 1.5 0 0 1 20 5.5V9'
          'M20 15v3.5a1.5 1.5 0 0 1-1.5 1.5H15M9 20H5.5A1.5 1.5 0 0 1 4 18.5V15'),
    ]);
final icoSearch = Ico(() => [_c(10.8, 10.8, 6.8), _svg('M15.8 15.8L21 21')]);
final icoClose = Ico(() => [_svg('M6 6l12 12M18 6L6 18')]);
final icoCheck = Ico(() => [_svg('M5 12.5l4.5 4.5L19 7')]);

class LineIcon extends StatelessWidget {
  const LineIcon(
    this.ico, {
    super.key,
    this.size = 22,
    this.color = T.fg,
    this.stroke = 1.35,
  });

  final Ico ico;
  final double size;
  final Color color;
  final double stroke;

  @override
  Widget build(BuildContext context) => SizedBox(
        width: size,
        height: size,
        child: CustomPaint(
          painter: _IcoPainter(ico: ico, color: color, stroke: stroke),
        ),
      );
}

class _IcoPainter extends CustomPainter {
  _IcoPainter({required this.ico, required this.color, required this.stroke});

  final Ico ico;
  final Color color;
  final double stroke;

  @override
  void paint(Canvas canvas, Size size) {
    final s = size.width / 24.0;
    canvas.save();
    canvas.scale(s);
    final line = Paint()
      ..style = PaintingStyle.stroke
      ..color = color
      ..strokeWidth = stroke
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..isAntiAlias = true;
    for (final p in ico.stroke()) {
      canvas.drawPath(p, line);
    }
    final fill = ico.fill;
    if (fill != null) {
      final solid = Paint()
        ..style = PaintingStyle.fill
        ..color = color
        ..isAntiAlias = true;
      for (final p in fill()) {
        canvas.drawPath(p, solid);
      }
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _IcoPainter old) =>
      old.color != color || old.stroke != stroke || old.ico != ico;
}

/// 极简 SVG 路径解析：只覆盖设计稿里出现的命令，够用且没有第三方依赖。
class SvgPathParser {
  const SvgPathParser._();

  static final RegExp _token =
      RegExp(r'[MmLlHhVvCcSsQqTtAaZz]|-?\d*\.?\d+(?:[eE][-+]?\d+)?');

  static Path parse(String d) {
    final path = Path();
    final tokens =
        _token.allMatches(d).map((m) => m.group(0)!).toList(growable: false);
    var i = 0;
    var cmd = '';
    var prev = '';
    var cx = 0.0, cy = 0.0, sx = 0.0, sy = 0.0;
    double? ctrlX, ctrlY;

    double num() => i < tokens.length ? double.parse(tokens[i++]) : 0;

    while (i < tokens.length) {
      final t = tokens[i];
      if (t.length == 1 && RegExp(r'[A-Za-z]').hasMatch(t)) {
        cmd = t;
        i++;
      }
      if (cmd.isEmpty) break;
      final upper = cmd.toUpperCase();
      final rel = cmd != upper;

      switch (upper) {
        case 'M':
          final x = num(), y = num();
          cx = rel ? cx + x : x;
          cy = rel ? cy + y : y;
          path.moveTo(cx, cy);
          sx = cx;
          sy = cy;
          prev = 'M';
          // 后续坐标对按 lineto 处理（SVG 规范）
          cmd = rel ? 'l' : 'L';
          break;
        case 'L':
          final x = num(), y = num();
          cx = rel ? cx + x : x;
          cy = rel ? cy + y : y;
          path.lineTo(cx, cy);
          prev = 'L';
          break;
        case 'H':
          final x = num();
          cx = rel ? cx + x : x;
          path.lineTo(cx, cy);
          prev = 'H';
          break;
        case 'V':
          final y = num();
          cy = rel ? cy + y : y;
          path.lineTo(cx, cy);
          prev = 'V';
          break;
        case 'C':
          var x1 = num(), y1 = num(), x2 = num(), y2 = num();
          var x = num(), y = num();
          if (rel) {
            x1 += cx;
            y1 += cy;
            x2 += cx;
            y2 += cy;
            x += cx;
            y += cy;
          }
          path.cubicTo(x1, y1, x2, y2, x, y);
          ctrlX = x2;
          ctrlY = y2;
          cx = x;
          cy = y;
          prev = 'C';
          break;
        case 'S':
          var x2 = num(), y2 = num();
          var x = num(), y = num();
          if (rel) {
            x2 += cx;
            y2 += cy;
            x += cx;
            y += cy;
          }
          final x1 = (prev == 'C' || prev == 'S') ? 2 * cx - (ctrlX ?? cx) : cx;
          final y1 = (prev == 'C' || prev == 'S') ? 2 * cy - (ctrlY ?? cy) : cy;
          path.cubicTo(x1, y1, x2, y2, x, y);
          ctrlX = x2;
          ctrlY = y2;
          cx = x;
          cy = y;
          prev = 'S';
          break;
        case 'Q':
          var x1 = num(), y1 = num();
          var x = num(), y = num();
          if (rel) {
            x1 += cx;
            y1 += cy;
            x += cx;
            y += cy;
          }
          path.quadraticBezierTo(x1, y1, x, y);
          ctrlX = x1;
          ctrlY = y1;
          cx = x;
          cy = y;
          prev = 'Q';
          break;
        case 'T':
          var x = num(), y = num();
          if (rel) {
            x += cx;
            y += cy;
          }
          final x1 = (prev == 'Q' || prev == 'T') ? 2 * cx - (ctrlX ?? cx) : cx;
          final y1 = (prev == 'Q' || prev == 'T') ? 2 * cy - (ctrlY ?? cy) : cy;
          path.quadraticBezierTo(x1, y1, x, y);
          ctrlX = x1;
          ctrlY = y1;
          cx = x;
          cy = y;
          prev = 'T';
          break;
        case 'A':
          final rx = num(), ry = num();
          num(); // x-axis-rotation：设计稿里的弧都是正圆，忽略
          final large = num() != 0;
          final sweep = num() != 0;
          final x = num(), y = num();
          final nx = rel ? cx + x : x;
          final ny = rel ? cy + y : y;
          if (rx.abs() < 0.01 || ry.abs() < 0.01) {
            path.lineTo(nx, ny);
          } else {
            path.arcToPoint(
              Offset(nx, ny),
              radius: Radius.elliptical(rx.abs(), ry.abs()),
              largeArc: large,
              clockwise: sweep,
            );
          }
          cx = nx;
          cy = ny;
          prev = 'A';
          break;
        case 'Z':
          path.close();
          cx = sx;
          cy = sy;
          prev = 'Z';
          // 闭合后若紧跟数字而非命令，说明数据不规范，直接收尾避免死循环
          if (i < tokens.length &&
              !(tokens[i].length == 1 &&
                  RegExp(r'[A-Za-z]').hasMatch(tokens[i]))) {
            return path;
          }
          break;
        default:
          return path;
      }
    }
    return path;
  }
}
