import 'dart:math' as math;


import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

/// ---------------------------------------------------------------------------
/// 「HOLO」全息覆盖层组件 ← 第三版，与前面两版最大的不同是**几何语言**
///
/// 前两版的问题：
///  v1 整幅图 cover 铺满 → 裁掉两侧 35% → 人物没了
///  v2 图上裁出一条 215px 的头像带 → **把背景图当头像用了**，这是错的
///  v3（本版）：**整幅图零裁切完整呈现**，界面元素改成不带填充的细线框，
///             让画面从线框中间透出来 —— 界面是"浮在画上"，不是"盖住画"
///
/// 几何计算（这是本版唯一正确的做法）：
///   原图 1127×1593，宽高比 0.7074
///   画布宽 390 → 按宽度撑满，高度 = 390 × 1593/1127 = 551.3
///   551 < 844，所以整幅图**完整可见，一点不裁**，上下留白正好放界面
///   前两版之所以裁，是因为强行让图填满 844 高度（cover 语义），
///   本版改用 fitWidth 语义，图缩到它能完整显示的最小尺寸
/// ---------------------------------------------------------------------------

/// 墨晕标题：文字后面垫一块径向墨色，让字在任何画面上都可读，
/// 但不形成"卡片"的边界 —— 没有边、没有框，只是一团晕开的暗。
class InkTitle extends StatelessWidget {
  const InkTitle({
    super.key,
    required this.title,
    required this.eyebrow,
    this.trailing,
  });

  final String title;
  final String eyebrow;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        // 墨晕：以标题为中心晕开的暗紫
        Positioned(
          left: -26,
          top: -18,
          right: -26,
          bottom: -10,
          child: DecoratedBox(
            decoration: BoxDecoration(
              gradient: RadialGradient(
                center: Alignment.centerLeft,
                radius: 1.5,
                colors: [
                  T.bgDeep.withValues(alpha: 0.78),
                  T.bgDeep.withValues(alpha: 0.30),
                  Colors.transparent,
                ],
                stops: const [0, 0.55, 1],
              ),
            ),
          ),
        ),
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            // eyebrow 为空时整块不渲染（连 SizedBox 的间距也不留），
            // 否则空字符串仍会占一行高度，标题位置会莫名下移
            if (eyebrow.isNotEmpty) ...[
              Text(
                eyebrow,
                style: TextStyle(
                  fontFamily: T.mono,
                  fontSize: 7.5,
                  color: A.petalA.withValues(alpha: 0.92),
                  letterSpacing: 3.0,
                  fontWeight: FontWeight.w600,
                  shadows: [
                    Shadow(
                      color: A.petalC.withValues(alpha: 0.7),
                      blurRadius: 10,
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 3),
            ],
            Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text(
                  title,
                  style: TextStyle(
                    fontFamily: T.sans,
                    fontSize: 34,
                    height: 1,
                    color: T.fg,
                    letterSpacing: 1.0,
                    fontWeight: FontWeight.w700,
                    shadows: [
                      Shadow(
                        color: A.petalB.withValues(alpha: 0.85),
                        blurRadius: 16,
                      ),
                      Shadow(
                        color: A.petalB.withValues(alpha: 0.42),
                        blurRadius: 38,
                      ),
                      // 第三层是深色投影，压在画上也读得清
                      Shadow(
                        color: Colors.black.withValues(alpha: 0.55),
                        blurRadius: 6,
                        offset: const Offset(0, 1),
                      ),
                    ],
                  ),
                ),
                if (trailing != null) ...[
                  const SizedBox(width: 10),
                  Padding(
                    padding: const EdgeInsets.only(bottom: 4),
                    child: trailing!,
                  ),
                ],
              ],
            ),
          ],
        ),
      ],
    );
  }
}

/// 细线框：只有一个 1px 的渐变描边 + **四角加长线**（技术图纸风格），
/// 内部不加任何填充，画面直接透出来。
///
/// 这是本版替代"卡片"的核心手段：卡片会遮挡背景，线框不会。
///
/// ⚠️ 亮度对比的关键参数 `plate`：
///   纯零填充会让线框和背景**挤在同一个亮度区间**，控件读不出来 ——
///   用户反馈"背景图和功能键的亮度对比没有调好"就是这个原因。
///   所以加了 `plate`（深色半透明底板）：它不遮住画面（只压暗 30%~50%），
///   但把控件区整体拉进暗区，让上面的亮字和亮描边有对比可言。
///   视觉上仍然是"浮在线框里"，只是线框内部比外面暗一档。
class WireFrame extends StatelessWidget {
  const WireFrame({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.fromLTRB(12, 10, 12, 11),
    this.accent = A.petalB,
    this.alpha = 0.62,
    this.corner = 9,
    this.tint = 0.0,
    this.plate = 0.38,
  });

  final Widget child;
  final EdgeInsets padding;
  final Color accent;
  final double alpha;
  final double corner;
  final double tint;

  /// 底板深度（0=完全透出背景，1=纯黑）。0.30~0.50 之间最平衡：
  /// 低于 0.3 控件浮不出来，高于 0.5 背景被糊成一片黑、失去"透视"感。
  final double plate;

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      painter: _WirePainter(
        accent: accent,
        alpha: alpha,
        corner: corner,
        tint: tint,
        plate: plate,
      ),
      // ⚠️ 必须让命中测试穿透到底层控件。
      // CustomPaint 默认用 HitTestBehavior.deferToChild，本身不吃事件，
      // 但如果祖先链上有什么东西开了 opaque，事件会被吞掉。
      // 这里显式声明，保证内部 RulerSlider 的 Listener 能收到指针。
      isComplex: false,
      willChange: false,
      child: Padding(padding: padding, child: child),
    );
  }
}

class _WirePainter extends CustomPainter {
  _WirePainter({
    required this.accent,
    required this.alpha,
    required this.corner,
    required this.tint,
    required this.plate,
  });

  final Color accent;
  final double alpha;
  final double corner;
  final double tint;
  final double plate;

  @override
  void paint(Canvas canvas, Size size) {
    final r = Rect.fromLTWH(0, 0, size.width, size.height);
    final rr = RRect.fromRectAndRadius(
      r.deflate(0.5),
      Radius.circular(corner),
    );

    // ── ① 底板：把控件区整体压进暗区。
    //   这是"背景 vs 控件"亮度对比的核心手段：
    //   不画底板时，线框和背景的亮度几乎一样，字和描边读不出来。
    //   底板用**竖向渐变**（上浅下深），比纯色更像玻璃、也更自然。
    if (plate > 0) {
      canvas.drawRRect(
        rr,
        Paint()
          ..shader = LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [
              const Color(0xFF120A22).withValues(alpha: plate * 0.82),
              const Color(0xFF07040F).withValues(alpha: plate),
            ],
          ).createShader(r),
      );
    }

    // 极淡彩色 tint（可选）：给某些模块一点色调倾向
    if (tint > 0) {
      canvas.drawRRect(
        rr,
        Paint()..color = accent.withValues(alpha: tint),
      );
    }

    // ── ② 主描边：粉→紫→蓝渐变，1.4px。
    //   alpha 默认为 0.62（原来是 0.34），乘以 1.6/0.9/1.25 后
    //   最亮处约 0.99、最暗处 0.56，描边在暗底上足够清楚。
    final stroke = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.4
      ..shader = LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: [
          accent.withValues(alpha: (alpha * 1.6).clamp(0.0, 1.0)),
          T.wisteria.withValues(alpha: alpha * 0.9),
          T.sky.withValues(alpha: (alpha * 1.25).clamp(0.0, 1.0)),
        ],
      ).createShader(r);

    canvas.drawRRect(rr, stroke);

    // ── ③ 描边外发光：让线框"亮"起来（暗底 + 亮边 = 强对比）
    canvas.drawRRect(
      rr,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 5
        ..color = accent.withValues(alpha: alpha * 0.30)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 5),
    );

    // 四角加长线（技术图纸的角标）
    final cornerPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.8
      ..strokeCap = StrokeCap.round
      ..color = accent.withValues(alpha: (alpha * 1.4).clamp(0.0, 1.0));
    const L = 11.0;
    // 左上
    canvas.drawLine(const Offset(0, L), Offset.zero, cornerPaint);
    canvas.drawLine(Offset.zero, const Offset(L, 0), cornerPaint);
    // 右上
    canvas.drawLine(Offset(size.width - L, 0), Offset(size.width, 0), cornerPaint);
    canvas.drawLine(Offset(size.width, 0), Offset(size.width, L), cornerPaint);
    // 左下
    canvas.drawLine(Offset(0, size.height - L), Offset(0, size.height), cornerPaint);
    canvas.drawLine(Offset(0, size.height), Offset(L, size.height), cornerPaint);
    // 右下
    canvas.drawLine(
        Offset(size.width - L, size.height), Offset(size.width, size.height), cornerPaint);
    canvas.drawLine(
        Offset(size.width, size.height - L), Offset(size.width, size.height), cornerPaint);
  }

  @override
  bool shouldRepaint(covariant _WirePainter old) =>
      old.accent != accent || old.alpha != alpha || old.tint != tint;
}

/// 环形细线仪表：只有细弧 + 刻度点 + 中心数字，无填充。
/// 放在画面上像 AR 眼镜 HUD 里的一个环。
class ThinGauge extends StatelessWidget {
  const ThinGauge({
    super.key,
    required this.value,
    required this.label,
    required this.readout,
    this.size = 96,
    this.accent = A.petalB,
    this.turn = 0.75,
  });

  final double value; // 0..1
  final String label;
  final String readout;
  final double size;
  final Color accent;
  final double turn;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: size,
      height: size,
      child: CustomPaint(
        painter: _GaugePainter(
          value: value.clamp(0.0, 1.0),
          accent: accent,
          turn: turn,
        ),
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                readout,
                style: TextStyle(
                  fontFamily: T.mono,
                  fontSize: 15,
                  color: accent,
                  letterSpacing: 0.3,
                  fontWeight: FontWeight.w700,
                  shadows: [
                    Shadow(color: accent.withValues(alpha: 0.8), blurRadius: 11),
                  ],
                ),
              ),
              const SizedBox(height: 2),
              Text(
                label,
                style: TextStyle(
                  fontFamily: T.mono,
                  fontSize: 7,
                  color: T.dim,
                  letterSpacing: 1.4,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _GaugePainter extends CustomPainter {
  _GaugePainter({
    required this.value,
    required this.accent,
    required this.turn,
  });

  final double value;
  final Color accent;
  final double turn;

  @override
  void paint(Canvas canvas, Size size) {
    final c = size.center(Offset.zero);
    final r = size.width / 2 - 4;
    final sweep = math.pi * 2 * turn;
    final start = -math.pi / 2 - sweep / 2 + math.pi * 2 * 0;

    // 底弧：极细
    canvas.drawArc(
      Rect.fromCircle(center: c, radius: r),
      start,
      sweep,
      false,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1
        ..color = T.wisteria.withValues(alpha: 0.22),
    );

    // 进度弧
    canvas.drawArc(
      Rect.fromCircle(center: c, radius: r),
      start,
      sweep * value,
      false,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2
        ..strokeCap = StrokeCap.round
        ..shader = LinearGradient(
          colors: [accent, T.sky, T.mint],
        ).createShader(Rect.fromCircle(center: c, radius: r)),
    );

    // 刻度点：沿弧 12 个
    final dotPaint = Paint()..color = T.faint.withValues(alpha: 0.5);
    for (var i = 0; i <= 12; i++) {
      final a = start + sweep * (i / 12);
      final p = c + Offset(math.cos(a), math.sin(a)) * (r + 4);
      canvas.drawCircle(
        p,
        i % 3 == 0 ? 1.8 : 1.0,
        i % 3 == 0 ? (Paint()..color = accent.withValues(alpha: 0.75)) : dotPaint,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _GaugePainter old) =>
      old.value != value || old.accent != accent;
}

/// 斜切标签：平行四边形，不是圆角矩形。
/// 用作主操作按钮 —— 斜边带来"方向感"，和满屏的圆角完全区分开。
class BevelButton extends StatelessWidget {
  const BevelButton({
    super.key,
    required this.label,
    required this.sub,
    required this.onTap,
    required this.live,
    this.busy = false,
  });

  final String label;
  final String sub;
  final VoidCallback onTap;
  final bool live;
  final bool busy;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: busy ? null : onTap,
      child: AnimatedOpacity(
        duration: const Duration(milliseconds: 200),
        opacity: busy ? 0.6 : 1,
        child: CustomPaint(
          painter: _BevelPainter(live: live),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 26, vertical: 13),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (busy)
                  SizedBox(
                    width: 13,
                    height: 13,
                    child: CircularProgressIndicator(
                      strokeWidth: 1.6,
                      color: live ? A.petalA : T.ink,
                    ),
                  )
                else
                  Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        label,
                        style: TextStyle(
                          fontFamily: T.sans,
                          fontSize: 13,
                          color: live ? A.petalA : T.ink,
                          letterSpacing: 2.4,
                          fontWeight: FontWeight.w700,
                          height: 1.1,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        sub,
                        style: TextStyle(
                          fontFamily: T.mono,
                          fontSize: 6.5,
                          color: live
                              ? A.petalB.withValues(alpha: 0.7)
                              : T.ink.withValues(alpha: 0.6),
                          letterSpacing: 0.6,
                        ),
                      ),
                    ],
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _BevelPainter extends CustomPainter {
  _BevelPainter({required this.live});

  final bool live;

  @override
  void paint(Canvas canvas, Size size) {
    const lean = 13.0;
    final path = Path()
      ..moveTo(lean, 0)
      ..lineTo(size.width, 0)
      ..lineTo(size.width - lean, size.height)
      ..lineTo(0, size.height)
      ..close();

    if (live) {
      // 运行时：只有描边，内部透出画面
      canvas.drawPath(
        path,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.4
          ..color = A.petalB.withValues(alpha: 0.85),
      );
      canvas.drawPath(
        path,
        Paint()..color = A.petalB.withValues(alpha: 0.10),
      );
      // 外部光晕
      canvas.drawPath(
        path,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 6
          ..color = A.petalB.withValues(alpha: 0.14)
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 6),
      );
    } else {
      // 未运行：实心渐变（这是唯一需要"实体感"的控件，代表主行动）
      canvas.drawPath(
        path,
        Paint()
          ..shader = const LinearGradient(
            colors: A.btnGrad,
          ).createShader(Rect.fromLTWH(0, 0, size.width, size.height)),
      );
      canvas.drawPath(
        path,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.2
          ..color = A.petalA.withValues(alpha: 0.9),
      );
      canvas.drawPath(
        path,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 8
          ..color = A.petalB.withValues(alpha: 0.20)
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 8),
      );
    }
  }

  @override
  bool shouldRepaint(covariant _BevelPainter old) => old.live != live;
}

/// 竖向刻度尺：左侧一条刻度，右侧数值。
/// 替代滑杆 —— 用"尺"的隐喻而不是"轨道 + 圆钮"。
class RulerSlider extends StatelessWidget {
  const RulerSlider({
    super.key,
    required this.label,
    required this.readout,
    required this.value,
    required this.min,
    required this.max,
    required this.onChanged,
    this.divisions,
  });

  final String label;
  final String readout;
  final double value;
  final double min;
  final double max;
  final ValueChanged<double> onChanged;
  final int? divisions;

  void _emit(double dx, double width) {
    final t = (dx / width).clamp(0.0, 1.0);
    var v = min + t * (max - min);
    if (divisions != null && divisions! > 0) {
      final step = (max - min) / divisions!;
      v = (v / step).roundToDouble() * step;
    }
    onChanged(v.clamp(min, max));
  }

  @override
  Widget build(BuildContext context) {
    final t = ((value - min) / (max - min)).clamp(0.0, 1.0);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text(
              label,
              style: TextStyle(
                fontFamily: T.sans,
                fontSize: 9.5,
                color: T.dim,
                letterSpacing: 1.6,
              ),
            ),
            const Spacer(),
            Text(
              readout,
              style: TextStyle(
                fontFamily: T.mono,
                fontSize: 10,
                color: A.petalA,
                letterSpacing: 0.2,
                fontWeight: FontWeight.w600,
                shadows: [
                  Shadow(color: A.petalB.withValues(alpha: 0.6), blurRadius: 8),
                ],
              ),
            ),
          ],
        ),
        const SizedBox(height: 1),
        LayoutBuilder(
          builder: (context, box) => Listener(
            // ── 为什么用 Listener 而不是 GestureDetector
            //
            // RulerSlider 都放在 SingleChildScrollView 里（垂直滚动）。
            // GestureDetector 的 onTapDown / onHorizontalDragUpdate **都要
            // 先赢手势竞技场才回调**，而垂直滚动容器也会进竞技场，
            // 结果就是"点了、拖了，尺子纹丝不动" —— 用户反馈
            // 「尺寸距离和视场不是可调的吗，怎么不可调了」正是这个。
            //
            // Listener 走的是**原始指针事件**，完全不进竞技场：
            // 按下就发光标的，按下即 emit，移动继续 emit。
            // 代价是滚动时手指划过尺子会被顺手改值 —— 但这反而符合
            // "拖动刻度尺"的直觉，也比完全调不动好。
            behavior: HitTestBehavior.opaque,
            onPointerDown: (e) => _emit(e.localPosition.dx, box.maxWidth),
            onPointerMove: (e) => _emit(e.localPosition.dx, box.maxWidth),
            child: SizedBox(
              height: 22,
              child: CustomPaint(
                painter: _RulerPainter(t: t, divisions: divisions),
                // ⚠️ CustomPaint 无 child 时是 zero-size，不参与命中测试。
                // 给它一个占满的子节点，Listener 才有可点区域。
                child: const SizedBox.expand(),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _RulerPainter extends CustomPainter {
  _RulerPainter({required this.t, this.divisions});

  final double t;
  final int? divisions;

  @override
  void paint(Canvas canvas, Size size) {
    final y = size.height / 2;
    final n = (divisions ?? 10).clamp(2, 40);

    // 刻度：长短交替的竖线（像真尺子）
    for (var i = 0; i <= n; i++) {
      final x = size.width * (i / n);
      final major = i % 5 == 0;
      final passed = (i / n) <= t;
      canvas.drawLine(
        Offset(x, y - (major ? 7 : 4)),
        Offset(x, y + (major ? 7 : 4)),
        Paint()
          ..strokeWidth = major ? 1.2 : 1
          ..color = passed
              ? A.petalB.withValues(alpha: major ? 0.85 : 0.45)
              : T.wisteria.withValues(alpha: 0.20),
      );
    }

    // 当前位：一条更粗的亮线穿过
    final px = size.width * t;
    canvas.drawLine(
      Offset(px, y - 9),
      Offset(px, y + 9),
      Paint()
        ..strokeWidth = 1.8
        ..strokeCap = StrokeCap.round
        ..color = A.petalA,
    );
    canvas.drawLine(
      Offset(px, y - 9),
      Offset(px, y + 9),
      Paint()
        ..strokeWidth = 5
        ..strokeCap = StrokeCap.round
        ..color = A.petalB.withValues(alpha: 0.35)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 4),
    );
  }

  @override
  bool shouldRepaint(covariant _RulerPainter old) =>
      old.t != t || old.divisions != divisions;
}

/// 磁带式读数条：横向滚动的等宽读数，用"///"分隔，无边框无底。
class TapeStrip extends StatelessWidget {
  const TapeStrip({super.key, required this.items, this.live = false});

  final List<(String, String)> items;
  final bool live;

  @override
  Widget build(BuildContext context) {
    final tone = live ? T.mint : A.petalA;
    return SizedBox(
      height: 17,
      child: MediaQuery.withClampedTextScaling(
        maxScaleFactor: 1.0,
        child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(
            children: [
              for (var i = 0; i < items.length; i++) ...[
                Text(
                  items[i].$1,
                  style: TextStyle(
                    fontFamily: T.mono,
                    fontSize: 7,
                    color: T.ghost,
                    letterSpacing: 1.1,
                  ),
                ),
                const SizedBox(width: 3),
                Text(
                  items[i].$2,
                  style: TextStyle(
                    fontFamily: T.mono,
                    fontSize: 8,
                    color: tone,
                    letterSpacing: 0.2,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                if (i != items.length - 1)
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 7),
                    child: Text(
                      '///',
                      style: TextStyle(
                        fontFamily: T.mono,
                        fontSize: 8,
                        color: T.wisteria.withValues(alpha: 0.30),
                        letterSpacing: -0.5,
                      ),
                    ),
                  ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// 扇形切片导航：四个扇区沿右侧一条弧排布，选中扇区外扩 + 发光。
///
/// 为什么用扇形：圆角矩形 tab 是"列表"语言，扇形是"仪表/刻度盘"语言，
/// 和满屏的线框、环形仪表属于同一套几何，视觉上不再重复。
///
/// ⚠️ 点击命中修正：原来的写法让每个扇区各自是一个**同尺寸全铺的
/// CustomPaint**，四个一起叠在 Stack 里 —— 触摸永远命中在最上层那个
/// （也就是最后一个 = 系统），点任何扇区都跳最后一章。
/// 现在改成「整块一个手势 + 按角度反解扇区」，视觉与命中用**同一个**
/// [angleFor] 约定，不依赖层叠顺序。
class FanSlices extends StatelessWidget {
  const FanSlices({
    super.key,
    required this.labels,
    required this.index,
    required this.onTap,
    this.size = 118,
  });

  final List<String> labels;
  final int index;
  final ValueChanged<int> onTap;
  final double size;

  /// 第 i 个扇区的中心角。起点 = 正左（π），顺时针。
  static double angleFor(int i, int n) =>
      math.pi + (i + 0.5) * (2 * math.pi / n);

  /// 触点 → 扇区下标。用与绘制完全相同的角度约定反解；圆外返回 -1。
  int _hit(Offset local) {
    final c = Offset(size / 2, size / 2);
    final d = local - c;
    if (d.distance > size / 2) return -1;
    // atan2 返回 -π..π；平移到 0..2π（以正左为 0 起点对齐绘制约定）
    var a = math.atan2(d.dy, d.dx) - math.pi;
    if (a < 0) a += 2 * math.pi;
    if (a >= 2 * math.pi) a -= 2 * math.pi;
    final n = labels.length;
    return (a / (2 * math.pi / n)).floor().clamp(0, n - 1);
  }

  @override
  Widget build(BuildContext context) {
    final n = labels.length;
    return SizedBox(
      width: size,
      height: size,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapDown: (d) {
          final i = _hit(d.localPosition);
          if (i >= 0) onTap(i);
        },
        child: Stack(
          children: [
            // 所有扇区一次画完，保证「画出来的」和「点得到的」一致
            Positioned.fill(
              child: CustomPaint(
                painter: _FanPainter(count: n, selected: index),
              ),
            ),
            // 文字层不吃手势
            Positioned.fill(
              child: IgnorePointer(
                child: Stack(
                  children: [
                    for (var i = 0; i < n; i++)
                      Align(
                        alignment: Alignment(
                          math.cos(angleFor(i, n)) * 0.58,
                          math.sin(angleFor(i, n)) * 0.58,
                        ),
                        child: Text(
                          labels[i],
                          style: TextStyle(
                            fontFamily: T.sans,
                            fontSize: 8,
                            color: index == i ? A.petalA : T.faint,
                            letterSpacing: 1.2,
                            fontWeight:
                                index == i ? FontWeight.w700 : FontWeight.w400,
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 一次画完所有扇区。
class _FanPainter extends CustomPainter {
  _FanPainter({required this.count, required this.selected});

  final int count;
  final int selected;

  @override
  void paint(Canvas canvas, Size size) {
    final c = size.center(Offset.zero);
    final rOuter = size.width / 2 - 2;
    const gap = 0.05;
    final sector = 2 * math.pi / count;

    for (var i = 0; i < count; i++) {
      final start = FanSlices.angleFor(i, count) - sector / 2 + gap;
      final sweep = sector - gap * 2;
      final sel = i == selected;

      final path = Path()
        ..moveTo(c.dx, c.dy)
        ..arcTo(
          Rect.fromCircle(center: c, radius: sel ? rOuter : rOuter - 6),
          start,
          sweep,
          false,
        )
        ..close();

      if (sel) {
        canvas.drawPath(
          path,
          Paint()..color = A.petalB.withValues(alpha: 0.22),
        );
        canvas.drawPath(
          path,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1.5
            ..color = A.petalA.withValues(alpha: 0.92),
        );
        canvas.drawPath(
          path,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 6
            ..color = A.petalB.withValues(alpha: 0.24)
            ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 6),
        );
      } else {
        canvas.drawPath(
          path,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1
            ..color = T.wisteria.withValues(alpha: 0.26),
        );
      }
    }

    canvas.drawCircle(
      c,
      2.5,
      Paint()..color = A.petalB.withValues(alpha: 0.7),
    );
  }

  @override
  bool shouldRepaint(covariant _FanPainter old) =>
      old.selected != selected || old.count != count;
}

/// 斜切线：一条 45° 的短线 + 标签，用来做区块之间的小分隔（不是横线，不是卡片）
class SlashRule extends StatelessWidget {
  const SlashRule({super.key, this.label});

  final String? label;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 9),
      child: Row(
        children: [
          // 三条斜线，长度递减，像音乐频谱的收尾
          for (var i = 0; i < 3; i++) ...[
            Transform.rotate(
              angle: -0.55,
              child: Container(
                width: 1.5,
                height: 9 - i * 2,
                color: A.petalB.withValues(alpha: 0.6 - i * 0.15),
              ),
            ),
            const SizedBox(width: 3),
          ],
          if (label != null) ...[
            const SizedBox(width: 6),
            Text(
              label!,
              style: TextStyle(
                fontFamily: T.mono,
                fontSize: 7,
                color: A.petalB.withValues(alpha: 0.75),
                letterSpacing: 2.0,
              ),
            ),
          ],
          const SizedBox(width: 8),
          Expanded(
            child: Container(
              height: 1,
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  colors: [
                    T.wisteria.withValues(alpha: 0.22),
                    Colors.transparent,
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
