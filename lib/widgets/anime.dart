import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

/// ---------------------------------------------------------------------------
/// 二次元装饰组件库
///
/// 设计语言：赛璐璐动画（cel-shading）——实色块 + 亮描边 + 光晕，不用柔和阴影。
/// 所有装饰只吃 CPU 的轻量绘制，不吃图片资源（包体不加 1 字节）。
/// ---------------------------------------------------------------------------

// =============================================================== 樱花飘落背景

/// 樱花飘落：Canvas 逐帧画的粒子系统。
///
/// 性能取舍：默认 12 片、30fps 节流（`_kFrameMs`），静止时暂停。
/// 用 `RepaintBoundary` 隔离，不让它触发整页重绘。
class SakuraFall extends StatefulWidget {
  const SakuraFall({
    super.key,
    this.count = 12,
    this.opacity = 0.55,
    this.enabled = true,
  });

  final int count;
  final double opacity;
  final bool enabled;

  @override
  State<SakuraFall> createState() => _SakuraFallState();
}

class _SakuraFallState extends State<SakuraFall>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c;
  late final List<_Petal> _petals;
  final _rnd = math.Random(20261105);

  @override
  void initState() {
    super.initState();
    // 30fps 足够，60fps 对飘落这种慢动作是浪费
    _c = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 1),
    );
    if (widget.enabled) _c.repeat();
    _petals = List.generate(widget.count, (_) => _Petal.spawn(_rnd));
  }

  @override
  void didUpdateWidget(covariant SakuraFall old) {
    super.didUpdateWidget(old);
    if (widget.enabled && !_c.isAnimating) {
      _c.repeat();
    } else if (!widget.enabled && _c.isAnimating) {
      _c.stop();
    }
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.enabled) return const SizedBox.shrink();
    return IgnorePointer(
      child: RepaintBoundary(
        child: AnimatedBuilder(
          animation: _c,
          builder: (_, _) => CustomPaint(
            painter: _SakuraPainter(_petals, widget.opacity),
            size: Size.infinite,
          ),
        ),
      ),
    );
  }
}

class _Petal {
  double x = 0; // 0..1 归一化
  double y = 0;
  double speed = 0;
  double drift = 0;
  double phase = 0;
  double rot = 0;
  double rotSpeed = 0;
  double scale = 1;
  Color color = A.petalA;

  static _Petal spawn(math.Random r) => _Petal()
    ..x = r.nextDouble()
    ..y = r.nextDouble()
    ..speed = 0.06 + r.nextDouble() * 0.10
    ..drift = 0.02 + r.nextDouble() * 0.05
    ..phase = r.nextDouble() * math.pi * 2
    ..rot = r.nextDouble() * math.pi * 2
    ..rotSpeed = (r.nextDouble() - 0.5) * 1.4
    ..scale = 0.55 + r.nextDouble() * 0.75
    ..color = [A.petalA, A.petalB, A.petalC][r.nextInt(3)];
}

class _SakuraPainter extends CustomPainter {
  _SakuraPainter(this.petals, this.opacity);

  final List<_Petal> petals;
  final double opacity;

  @override
  void paint(Canvas canvas, Size size) {
    final t = DateTime.now().millisecondsSinceEpoch / 1000.0;
    final paint = Paint()..style = PaintingStyle.fill;
    for (final p in petals) {
      // 用时间驱动而不是依赖 controller.value，避免 build 里读动画值
      final y = (p.y + t * p.speed) % 1.0;
      final x = (p.x + math.sin(t * 0.7 + p.phase) * p.drift) % 1.0;
      final cx = x * size.width;
      final cy = y * size.height;
      // 顶端淡出、底端淡入，像真的从画面上方飘进来
      final fade = math.min(1.0, math.min(y * 4, (1 - y) * 3));
      if (fade <= 0) continue;

      paint.color = p.color.withValues(alpha: opacity * fade);
      canvas.save();
      canvas.translate(cx, cy);
      canvas.rotate(p.rot + t * p.rotSpeed);
      canvas.scale(p.scale);
      // 花瓣形状：两段贝塞尔，尖端
      final path = Path()
        ..moveTo(0, -5)
        ..quadraticBezierTo(4.2, -2.6, 3.1, 1.6)
        ..quadraticBezierTo(1.4, 3.0, 0, 1.7)
        ..quadraticBezierTo(-1.4, 3.0, -3.1, 1.6)
        ..quadraticBezierTo(-4.2, -2.6, 0, -5)
        ..close();
      canvas.drawPath(path, paint);
      canvas.restore();
    }
  }

  @override
  bool shouldRepaint(covariant _SakuraPainter old) =>
      old.opacity != opacity || old.petals != petals;
}

// =============================================================== 霓虹描边卡片

/// 赛璐璐卡片：实色块 + 渐变霓虹描边 + 外发光。
///
/// 描边用 `CustomPaint` 画渐变环（Flutter 的 `Border` 不支持渐变描边）。
class CelCard extends StatelessWidget {
  const CelCard({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.fromLTRB(18, 16, 18, 18),
    this.glow = true,
    this.grad = A.cardEdge,
    this.radius = T.rCard,
    this.fill = T.card,
  });

  final Widget child;
  final EdgeInsets padding;
  final bool glow;
  final List<Color> grad;
  final double radius;
  final Color fill;

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      painter: _EdgePainter(
        radius: radius,
        grad: grad,
        glow: glow,
        strokeWidth: A.stroke,
      ),
      child: Container(
        decoration: BoxDecoration(
          color: fill,
          borderRadius: BorderRadius.circular(radius),
        ),
        padding: padding,
        child: child,
      ),
    );
  }
}

class _EdgePainter extends CustomPainter {
  _EdgePainter({
    required this.radius,
    required this.grad,
    required this.glow,
    required this.strokeWidth,
  });

  final double radius;
  final List<Color> grad;
  final bool glow;
  final double strokeWidth;

  @override
  void paint(Canvas canvas, Size size) {
    final rrect = RRect.fromRectAndRadius(
      Rect.fromLTWH(0, 0, size.width, size.height).deflate(strokeWidth / 2),
      Radius.circular(radius),
    );
    final rect = rrect.outerRect;
    final shader = LinearGradient(
      begin: Alignment.topLeft,
      end: Alignment.bottomRight,
      colors: [
        for (final c in grad) c.withValues(alpha: 0.85),
      ],
    ).createShader(rect);

    if (glow) {
      // 先画一层宽而淡的描边当光晕，再叠实描边——比 BoxShadow 便宜
      canvas.drawRRect(
        rrect,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = strokeWidth * 5
          ..color = grad.first.withValues(alpha: 0.10)
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 8),
      );
    }
    canvas.drawRRect(
      rrect,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = strokeWidth
        ..shader = shader,
    );
  }

  @override
  bool shouldRepaint(covariant _EdgePainter old) =>
      old.radius != radius || old.glow != glow || old.grad != grad;
}

// =============================================================== 标题条

/// 页头：霓虹竖条 + 发光标题 + 状态胶囊 + 副标题。
///
/// v2 改成**纵向紧凑型**：原先胶囊和标题横排，在左侧窄面板（约 240px）
/// 里会把标题挤成省略号。现在改成「眉题 → 大标题 → 胶囊 → 副标题」四行，
/// 胶囊单独一行贴左，标题永远有满宽可用。
class AnimeHeader extends StatelessWidget {
  const AnimeHeader({
    super.key,
    required this.eyebrow,
    required this.title,
    required this.pill,
    this.subtitle,
  });

  final String eyebrow;
  final String title;
  final Widget pill;
  final String? subtitle;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            // 左侧霓虹竖条
            Container(
              width: 3.5,
              height: 24,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(2),
                gradient: const LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: A.cardEdge,
                ),
                boxShadow: T.glow(A.petalB, blur: 14, alpha: 0.7),
              ),
            ),
            const SizedBox(width: 9),
            Expanded(
              child: Text(
                eyebrow.toUpperCase(),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: tm(
                  8,
                  color: A.petalB,
                  ls: 2.4,
                  weight: FontWeight.w600,
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 7),
        Text(
          title,
          style: tsGlow(24, ls: 1.4, height: 1.1),
        ),
        const SizedBox(height: 9),
        // 胶囊单独一行：窄面板里横排会挤爆
        Row(
          children: [
            pill,
            const Spacer(),
          ],
        ),
        if (subtitle != null) ...[
          const SizedBox(height: 9),
          Text(
            subtitle!,
            style: ts(9.5, color: T.faint, ls: 0.3, height: 1.5),
          ),
        ],
      ],
    );
  }
}

// =============================================================== 分格线

/// 漫画分格线：两端渐隐的斜线，用来分隔区块。
class PanelRule extends StatelessWidget {
  const PanelRule({super.key, this.label});

  final String? label;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 16),
      child: Row(
        children: [
          Expanded(
            child: Container(
              height: 1,
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  colors: [
                    T.wisteria.withValues(alpha: 0),
                    T.wisteria.withValues(alpha: 0.28),
                  ],
                ),
              ),
            ),
          ),
          if (label != null) ...[
            const SizedBox(width: 10),
            Text(
              label!,
              style: tm(8.5, color: T.faint, ls: 2.2),
            ),
            const SizedBox(width: 10),
          ],
          Expanded(
            child: Container(
              height: 1,
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  colors: [
                    T.wisteria.withValues(alpha: label != null ? 0.28 : 0),
                    T.wisteria.withValues(alpha: 0),
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

// =============================================================== 霓虹徽章

/// 小徽章：赛璐璐实色块 + 描边，用于"NEW""3DoF"这类角标。
class NeonBadge extends StatelessWidget {
  const NeonBadge({
    super.key,
    required this.text,
    this.color = A.petalB,
  });

  final String text;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.16),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: color.withValues(alpha: 0.62), width: 1),
        boxShadow: T.glow(color, blur: 12, alpha: 0.28),
      ),
      child: MediaQuery.withClampedTextScaling(
        maxScaleFactor: 1.15,
        child: Text(
          text,
          style: tm(9, color: color, ls: 1.2, weight: FontWeight.w700),
        ),
      ),
    );
  }
}

// =============================================================== 星尘分隔

/// 星尘：一排小圆点，越靠两端越淡（代替纯线条做分隔）。
class Stardust extends StatelessWidget {
  const Stardust({super.key, this.count = 11, this.color = A.petalB});

  final int count;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 16,
      child: Center(
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            for (var i = 0; i < count; i++) ...[
              Container(
                width: i == count ~/ 2 ? 4 : 2.5,
                height: i == count ~/ 2 ? 4 : 2.5,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: color.withValues(
                    alpha: 0.15 +
                        0.55 *
                            (1 -
                                (i - count ~/ 2).abs() /
                                    (count ~/ 2).toDouble()),
                  ),
                ),
              ),
              if (i != count - 1) const SizedBox(width: 6),
            ],
          ],
        ),
      ),
    );
  }
}

// =============================================================== 加载态

/// 二次元加载：绕轨道转的三颗星（不是系统 CircularProgressIndicator）。
class OrbitLoader extends StatefulWidget {
  const OrbitLoader({super.key, this.size = 42, this.label});

  final double size;
  final String? label;

  @override
  State<OrbitLoader> createState() => _OrbitLoaderState();
}

class _OrbitLoaderState extends State<OrbitLoader>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c;

  @override
  void initState() {
    super.initState();
    _c = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1800),
    )..repeat();
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox(
          width: widget.size,
          height: widget.size,
          child: AnimatedBuilder(
            animation: _c,
            builder: (_, _) => CustomPaint(
              painter: _OrbitPainter(_c.value),
              size: Size.square(widget.size),
            ),
          ),
        ),
        if (widget.label != null) ...[
          const SizedBox(height: 16),
          Text(widget.label!, style: tm(9.5, color: T.faint, ls: 2.2)),
        ],
      ],
    );
  }
}

class _OrbitPainter extends CustomPainter {
  _OrbitPainter(this.t);

  final double t;

  @override
  void paint(Canvas canvas, Size size) {
    final c = size.center(Offset.zero);
    final r = size.width / 2 - 6;
    // 轨道
    canvas.drawCircle(
      c,
      r,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1
        ..color = T.wisteria.withValues(alpha: 0.18),
    );
    // 三颗绕行星，错开 120°
    const colors = [A.petalB, T.sky, T.wisteria];
    for (var i = 0; i < 3; i++) {
      final a = t * math.pi * 2 + i * math.pi * 2 / 3;
      final p = c + Offset(math.cos(a) * r, math.sin(a) * r);
      canvas.drawCircle(
        p,
        3.2,
        Paint()
          ..color = colors[i]
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 1.2),
      );
      canvas.drawCircle(p, 1.7, Paint()..color = colors[i]);
    }
  }

  @override
  bool shouldRepaint(covariant _OrbitPainter old) => old.t != t;
}
