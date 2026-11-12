import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../theme/app_theme.dart';
import 'icons.dart';

/// ---------------------------------------------------------------------------
/// 「DECK」仪表盘组件词汇 — 彻底重构后的一套全新界面原语
///
/// 与旧的 ui.dart（卡片 + 行 + 分段控件 + 滑杆）不是同一套东西：
///  · TickerBar    顶部滚动读数条（像证券行情带/HUD 数据带）
///  · SpineRail    左侧书脊式竖排导航（文字旋转 90°，不是图标横排 tab）
///  · ModuleFold   折叠模块（收起时只剩一条摘要带，展开才铺开内容）
///  · FaderRail    调音台式推子（刻度齿 + 浮动数值牌，不是普通 slider）
///  · LedGrid      状态灯矩阵（一排小方块，亮灭表示子系统就绪）
///  · ArcDial      圆弧表盘（270° 弧 + 中心大字，替代大按钮）
///  · HorizonDial  人工地平仪（随 roll 旋转的天/地分界 + 俯仰刻度梯）
///  · ArtBand      顶部人物长卷轴（face 完整可见，是版面主角而非背景）
///
/// 设计原则：所有"读数"竖着写或贴着边写，所有"操作"是块状或圆形，
/// 版面靠不规则的形状区分层级，不靠卡片堆叠。
/// ---------------------------------------------------------------------------

// =============================================================== 顶部人物带

/// 顶部人物长卷轴。
///
/// 关键几何：原图 1127×1593 用 `BoxFit.cover` + `alignment: topCenter`
/// 在 390×230 的带子里只需缩放 0.346，画出来 390×551，纵向取顶部 42% ——
/// **横向一点不裁**，脸正好落在可见区。这就是"人物明显"的正解：
/// 不是调亮，而是换一个不裁宽度的取景框。
class ArtBand extends StatelessWidget {
  const ArtBand({
    super.key,
    required this.height,
    this.asset = 'assets/bg/bg_hero.jpg',
    this.child,
  });

  final double height;
  final String asset;
  final Widget? child;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: height,
      width: double.infinity,
      child: Stack(
        fit: StackFit.expand,
        children: [
          Image.asset(
            asset,
            fit: BoxFit.cover,
            alignment: Alignment.topCenter,
            filterQuality: FilterQuality.low,
            errorBuilder: (_, _, _) => const ColoredBox(color: T.bgLift),
          ),
          // 底部渐隐：让带子下缘和内容面板无缝接上
          DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  Colors.transparent,
                  T.bgDeep.withValues(alpha: 0.12),
                  T.bgDeep.withValues(alpha: 0.72),
                  T.bgDeep,
                ],
                stops: const [0.30, 0.62, 0.88, 1],
              ),
            ),
          ),
          // 左侧压暗：标题区永远压在暗处
          DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.centerLeft,
                end: Alignment.centerRight,
                colors: [
                  T.bgDeep.withValues(alpha: 0.70),
                  T.bgDeep.withValues(alpha: 0.10),
                  Colors.transparent,
                ],
                stops: const [0, 0.42, 0.78],
              ),
            ),
          ),
          ?child,
        ],
      ),
    );
  }
}

// =============================================================== 读数条

/// 顶部读数条：一串「标签=值」用细竖线隔开，横向可滚，像 HUD 数据带。
class TickerBar extends StatelessWidget {
  const TickerBar({super.key, required this.items, this.live = false});

  final List<(String, String)> items;
  final bool live;

  @override
  Widget build(BuildContext context) {
    final tone = live ? T.mint : T.faint;
    return Container(
      height: 30,
      padding: const EdgeInsets.symmetric(horizontal: 10),
      decoration: BoxDecoration(
        color: T.bgDeep.withValues(alpha: 0.82),
        border: Border(
          top: BorderSide(color: T.wisteria.withValues(alpha: 0.16)),
          bottom: BorderSide(color: T.wisteria.withValues(alpha: 0.16)),
        ),
      ),
      child: MediaQuery.withClampedTextScaling(
        maxScaleFactor: 1.0,
        child: Row(
          children: [
            Container(
              width: 5,
              height: 5,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: tone,
                boxShadow: live ? T.glow(tone, blur: 8, alpha: 0.8) : null,
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(
                  children: [
                    for (var i = 0; i < items.length; i++) ...[
                      Text(
                        items[i].$1,
                        style: tm(7.5, color: T.faint, ls: 0.9),
                      ),
                      const SizedBox(width: 4),
                      Text(
                        items[i].$2,
                        style: tm(
                          8.5,
                          color: live ? tone : T.dim,
                          ls: 0.2,
                          weight: FontWeight.w600,
                        ),
                      ),
                      if (i != items.length - 1)
                        Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 8),
                          child: Container(
                            width: 1,
                            height: 9,
                            color: T.wisteria.withValues(alpha: 0.22),
                          ),
                        ),
                    ],
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

// =============================================================== 书脊导航

/// 左侧书脊导航：标题文字**旋转 90°** 竖排，像书脊上的书名。
///
/// 为什么敢这么排：竖排中文在 390 宽度里只占 26px，省下的横向空间全给内容；
/// 而且文字竖向排列天然形成"章节"的隐喻，和折叠模块的结构对得上。
class SpineRail extends StatelessWidget {
  const SpineRail({
    super.key,
    required this.labels,
    required this.index,
    required this.onTap,
  });

  final List<String> labels;
  final int index;
  final ValueChanged<int> onTap;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 30,
      decoration: BoxDecoration(
        border: Border(
          right: BorderSide(color: T.wisteria.withValues(alpha: 0.14)),
        ),
      ),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          for (var i = 0; i < labels.length; i++)
            GestureDetector(
              key: ValueKey('spine_$i'),
              behavior: HitTestBehavior.opaque,
              onTap: () => onTap(i),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 280),
                margin: const EdgeInsets.symmetric(vertical: 5),
                padding: const EdgeInsets.symmetric(vertical: 10),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(13),
                  color: index == i
                      ? A.petalB.withValues(alpha: 0.16)
                      : Colors.transparent,
                  boxShadow: index == i
                      ? T.glow(A.petalB, blur: 16, alpha: 0.32)
                      : null,
                ),
                child: Center(
                  child: RotatedBox(
                    quarterTurns: 3,
                    child: Text(
                      labels[i],
                      maxLines: 1,
                      style: ts(
                        10,
                        ls: 2.2,
                        color: index == i ? A.petalA : T.faint,
                        weight:
                            index == i ? FontWeight.w700 : FontWeight.w400,
                      ),
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

// =============================================================== 折叠模块

/// 折叠模块：头部常驻（图标 + 标题 + 一行摘要 + 展开箭头），
/// 展开时才铺开内容。
///
/// 版面用意：把"必须一眼看到的摘要"和"偶尔才看的控件"分开。
/// 收起的模块只占 52px，四个模块全收起时一屏能看全 —— 这替代了 tab 导航。
class ModuleFold extends StatelessWidget {
  const ModuleFold({
    super.key,
    required this.title,
    required this.summary,
    required this.expanded,
    required this.onToggle,
    required this.body,
    this.icon,
    this.accent = A.petalB,
  });

  final String title;
  final String summary;
  final bool expanded;
  final VoidCallback onToggle;
  final Widget body;
  final Ico? icon;
  final Color accent;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 9),
      decoration: BoxDecoration(
        color: expanded
            ? T.bgLift.withValues(alpha: 0.72)
            : T.bgLift.withValues(alpha: 0.34),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: expanded
              ? accent.withValues(alpha: 0.42)
              : T.wisteria.withValues(alpha: 0.13),
          width: expanded ? 1.3 : 1,
        ),
        boxShadow:
            expanded ? T.glow(accent, blur: 22, alpha: 0.14) : null,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: onToggle,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 11, 12, 11),
              child: Row(
                children: [
                  if (icon != null) ...[
                    LineIcon(
                      icon!,
                      size: 15,
                      stroke: 1.5,
                      color: expanded ? accent : T.faint,
                    ),
                    const SizedBox(width: 9),
                  ],
                  Text(
                    title,
                    style: ts(
                      11.5,
                      ls: 0.8,
                      color: expanded ? T.fg : T.dim,
                      weight: expanded ? FontWeight.w700 : FontWeight.w500,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      summary,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: tm(7.5, color: T.faint, ls: 0.3),
                    ),
                  ),
                  AnimatedRotation(
                    duration: const Duration(milliseconds: 260),
                    turns: expanded ? 0.25 : 0,
                    child: LineIcon(
                      icoChevron,
                      size: 12,
                      stroke: 1.6,
                      color: expanded ? accent : T.faint,
                    ),
                  ),
                ],
              ),
            ),
          ),
          AnimatedSize(
            duration: const Duration(milliseconds: 300),
            curve: Curves.easeOutCubic,
            alignment: Alignment.topCenter,
            child: expanded
                ? Padding(
                    padding: const EdgeInsets.fromLTRB(12, 0, 12, 13),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Container(
                          height: 1,
                          color: accent.withValues(alpha: 0.20),
                        ),
                        const SizedBox(height: 11),
                        body,
                      ],
                    ),
                  )
                : const SizedBox(width: double.infinity, height: 0),
          ),
        ],
      ),
    );
  }
}

// =============================================================== 推子

/// 调音台式推子：轨道上有刻度齿，已走过段渐变填充，
/// 滑块上方浮一个数值牌（不是右侧读数）。
class FaderRail extends StatelessWidget {
  const FaderRail({
    super.key,
    required this.value,
    required this.min,
    required this.max,
    required this.onChanged,
    required this.readout,
    this.divisions,
  });

  final double value;
  final double min;
  final double max;
  final ValueChanged<double> onChanged;
  final String readout;
  final int? divisions;

  void _emit(double dx, double width) {
    const pad = 14.0;
    final travel = (width - pad * 2).clamp(1.0, double.infinity);
    var t = ((dx - pad) / travel).clamp(0.0, 1.0);
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
    return LayoutBuilder(
      builder: (context, box) {
        final w = box.maxWidth;
        final thumbX = 14 + (w - 28) * t;
        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTapDown: (d) => _emit(d.localPosition.dx, w),
          onHorizontalDragUpdate: (d) => _emit(d.localPosition.dx, w),
          child: SizedBox(
            height: 40,
            child: Stack(
              clipBehavior: Clip.none,
              children: [
                // 轨道 + 刻度 + 填充
                Positioned.fill(
                  child: CustomPaint(
                    painter: _FaderPainter(t: t, divisions: divisions),
                  ),
                ),
                // 浮动数值牌
                Positioned(
                  left: (thumbX - 26).clamp(0.0, math.max(0.0, w - 52)),
                  top: 0,
                  child: MediaQuery.withClampedTextScaling(
                    maxScaleFactor: 1.0,
                    child: Container(
                      width: 52,
                      padding: const EdgeInsets.symmetric(
                        horizontal: 6,
                        vertical: 2,
                      ),
                      decoration: BoxDecoration(
                        color: A.petalB.withValues(alpha: 0.16),
                        borderRadius: BorderRadius.circular(5),
                        border: Border.all(
                          color: A.petalB.withValues(alpha: 0.48),
                        ),
                      ),
                      child: Text(
                        readout,
                        textAlign: TextAlign.center,
                        maxLines: 1,
                        style: tm(
                          8.5,
                          color: A.petalA,
                          ls: 0.2,
                          weight: FontWeight.w700,
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _FaderPainter extends CustomPainter {
  _FaderPainter({required this.t, this.divisions});

  final double t;
  final int? divisions;

  @override
  void paint(Canvas canvas, Size size) {
    final y = size.height - 11;
    final x0 = 14.0;
    final x1 = size.width - 14;

    // 轨道
    canvas.drawLine(
      Offset(x0, y),
      Offset(x1, y),
      Paint()
        ..color = T.wisteria.withValues(alpha: 0.14)
        ..strokeWidth = 2
        ..strokeCap = StrokeCap.round,
    );

    // 刻度齿：上方短竖线
    final tickCount = (divisions ?? 8).clamp(2, 40);
    final tickPaint = Paint()
      ..color = T.wisteria.withValues(alpha: 0.20)
      ..strokeWidth = 1;
    for (var i = 0; i <= tickCount; i++) {
      final x = x0 + (x1 - x0) * (i / tickCount);
      final tall = i % 5 == 0;
      canvas.drawLine(
        Offset(x, y - (tall ? 8 : 5)),
        Offset(x, y - 2),
        tickPaint,
      );
    }

    // 已走过段：粉→紫渐变
    final px = x0 + (x1 - x0) * t;
    canvas.drawLine(
      Offset(x0, y),
      Offset(px, y),
      Paint()
        ..strokeWidth = 2.4
        ..strokeCap = StrokeCap.round
        ..shader = const LinearGradient(
          colors: [A.petalC, A.petalB, T.wisteria],
        ).createShader(Rect.fromLTRB(x0, y - 2, x1, y + 2)),
    );

    // 滑块：菱形（不是圆钮，和圆钮区分开）
    canvas.save();
    canvas.translate(px, y);
    canvas.rotate(math.pi / 4);
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromCenter(center: Offset.zero, width: 9, height: 9),
        const Radius.circular(2),
      ),
      Paint()..color = A.petalA,
    );
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromCenter(center: Offset.zero, width: 9, height: 9),
        const Radius.circular(2),
      ),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1
        ..color = A.petalC,
    );
    canvas.restore();

    // 滑块光晕
    canvas.drawCircle(
      Offset(px, y),
      8,
      Paint()
        ..color = A.petalB.withValues(alpha: 0.30)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 6),
    );
  }

  @override
  bool shouldRepaint(covariant _FaderPainter old) =>
      old.t != t || old.divisions != divisions;
}

// =============================================================== 状态灯矩阵

/// 状态灯矩阵：一行小方块，每块代表一个子系统，亮=就绪。
/// 点一下整块区域会回调（用于"去设置"这类动作）。
class LedGrid extends StatelessWidget {
  const LedGrid({super.key, required this.cells, this.vertical = false});

  /// 每格：(代号, 名称, 是否就绪, 点击回调)
  final List<(String, String, bool, VoidCallback?)> cells;
  final bool vertical;

  @override
  Widget build(BuildContext context) {
    final children = [
      for (final c in cells)
        GestureDetector(
          onTap: c.$4,
          child: MediaQuery.withClampedTextScaling(
            maxScaleFactor: 1.0,
            child: Container(
              padding: const EdgeInsets.symmetric(
                horizontal: 8,
                vertical: 6,
              ),
              decoration: BoxDecoration(
                color: c.$3
                    ? T.mint.withValues(alpha: 0.10)
                    : T.wisteria.withValues(alpha: 0.05),
                borderRadius: BorderRadius.circular(9),
                border: Border.all(
                  color: c.$3
                      ? T.mint.withValues(alpha: 0.40)
                      : T.wisteria.withValues(alpha: 0.15),
                ),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: 5,
                    height: 5,
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(1.5),
                      color: c.$3 ? T.mint : T.ghost,
                      boxShadow: c.$3
                          ? T.glow(T.mint, blur: 7, alpha: 0.9)
                          : null,
                    ),
                  ),
                  const SizedBox(width: 6),
                  Text(
                    c.$2,
                    style: tm(
                      7.5,
                      color: c.$3 ? T.mint : T.faint,
                      ls: 0.5,
                      weight: c.$3 ? FontWeight.w700 : FontWeight.w400,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
    ];
    return vertical
        ? Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (var i = 0; i < children.length; i++) ...[
                children[i],
                if (i != children.length - 1) const SizedBox(height: 6),
              ],
            ],
          )
        : Wrap(spacing: 6, runSpacing: 6, children: children);
  }
}

// =============================================================== 圆弧表盘

/// 圆弧表盘：270° 弧 + 中心大字，可点击当作主操作。
///
/// 替代"矩形大按钮"：圆是这台设备的主控形状（眼镜、头、视场都是圆的），
/// 而且圆盘中心天然适合放主操作文案。
class ArcDial extends StatelessWidget {
  const ArcDial({
    super.key,
    required this.progress,
    required this.label,
    required this.sublabel,
    this.onTap,
    this.busy = false,
    this.stop = false,
    this.size = 118,
  });

  final double progress; // 0..1
  final String label;
  final String sublabel;
  final VoidCallback? onTap;
  final bool busy;
  final bool stop;
  final double size;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: busy ? null : onTap,
      child: AnimatedOpacity(
        duration: const Duration(milliseconds: 200),
        opacity: busy ? 0.55 : 1,
        child: SizedBox(
          width: size,
          height: size,
          child: Stack(
            alignment: Alignment.center,
            children: [
              CustomPaint(
                painter: _ArcPainter(
                  progress: progress.clamp(0.0, 1.0),
                  stop: stop,
                ),
                size: Size.square(size),
              ),
              Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (busy)
                    SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(
                        strokeWidth: 1.7,
                        color: A.petalB,
                      ),
                    )
                  else
                    Text(
                      label,
                      style: ts(
                        13,
                        color: stop ? A.petalA : T.fg,
                        ls: 2.0,
                        weight: FontWeight.w700,
                        height: 1.1,
                      ),
                    ),
                  const SizedBox(height: 3),
                  Text(
                    sublabel,
                    style: tm(7.5, color: T.faint, ls: 0.5),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ArcPainter extends CustomPainter {
  _ArcPainter({required this.progress, required this.stop});

  final double progress;
  final bool stop;

  // 起始角 -225°，扫 270°（留出下方 90° 缺口，像仪表盘）
  static const _start = -math.pi * 1.25;
  static const _sweep = math.pi * 1.5;

  @override
  void paint(Canvas canvas, Size size) {
    final center = size.center(Offset.zero);
    final r = size.width / 2 - 8;

    // 底弧
    canvas.drawArc(
      Rect.fromCircle(center: center, radius: r),
      _start,
      _sweep,
      false,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 3
        ..color = T.wisteria.withValues(alpha: 0.13),
    );

    // 进度弧
    final tone = stop ? A.petalB : T.sky;
    canvas.drawArc(
      Rect.fromCircle(center: center, radius: r),
      _start,
      _sweep * progress,
      false,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 3.4
        ..strokeCap = StrokeCap.round
        ..shader = LinearGradient(
          colors: [A.petalC, tone, T.mint],
        ).createShader(Rect.fromCircle(center: center, radius: r)),
    );

    // 弧端亮点
    final a = _start + _sweep * progress;
    final p = center + Offset(math.cos(a) * r, math.sin(a) * r);
    canvas.drawCircle(
      p,
      7,
      Paint()
        ..color = tone.withValues(alpha: 0.45)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 5),
    );
    canvas.drawCircle(p, 3.2, Paint()..color = tone);

    // 内圈细环
    canvas.drawCircle(
      center,
      r - 12,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1
        ..color = T.wisteria.withValues(alpha: 0.16),
    );
  }

  @override
  bool shouldRepaint(covariant _ArcPainter old) =>
      old.progress != progress || old.stop != stop;
}

// =============================================================== 人工地平仪

/// 人工地平仪：随 roll 旋转的天/地分界 + 随 pitch 上下偏移 + 俯仰刻度梯。
///
/// 这是整页最"仪表"的一块：不用数字显示姿态，用姿态本身显示姿态。
/// 用户扫一眼就知道头偏了多少，读数只作为辅助。
class HorizonDial extends StatelessWidget {
  const HorizonDial({
    super.key,
    required this.yaw,
    required this.pitch,
    required this.roll,
    required this.tracking,
    this.size = 108,
  });

  final double yaw;
  final double pitch;
  final double roll;
  final bool tracking;
  final double size;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: size,
      height: size,
      child: ClipOval(
        child: CustomPaint(
          painter: _HorizonPainter(
            yaw: yaw.clamp(-60.0, 60.0),
            pitch: pitch.clamp(-30.0, 30.0),
            roll: roll.clamp(-60.0, 60.0),
            tracking: tracking,
          ),
          size: Size.square(size),
        ),
      ),
    );
  }
}

class _HorizonPainter extends CustomPainter {
  _HorizonPainter({
    required this.yaw,
    required this.pitch,
    required this.roll,
    required this.tracking,
  });

  final double yaw;
  final double pitch;
  final double roll;
  final bool tracking;

  @override
  void paint(Canvas canvas, Size size) {
    final c = size.center(Offset.zero);
    final r = size.shortestSide / 2;
    final k = tracking ? 1.0 : 0.35;

    canvas.save();
    canvas.translate(c.dx, c.dy);
    canvas.rotate(roll * math.pi / 180);

    // 天空：粉紫渐变
    final sky = Paint()
      ..shader = LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [
          A.petalB.withValues(alpha: 0.42 * k),
          T.wisteria.withValues(alpha: 0.22 * k),
        ],
      ).createShader(Rect.fromCircle(center: Offset.zero, radius: r));

    // 地面：深紫
    final ground = Paint()..color = T.bgDeep.withValues(alpha: 0.92);

    // 地平线随 pitch 上下平移（每度约 2.2px）
    final hy = -pitch * 2.2;
    canvas.drawRect(
      Rect.fromLTRB(-r * 2, -r * 2, r * 2, hy),
      sky,
    );
    canvas.drawRect(
      Rect.fromLTRB(-r * 2, hy, r * 2, r * 2),
      ground,
    );

    // 地平线：樱花色亮线
    canvas.drawLine(
      Offset(-r * 2, hy),
      Offset(r * 2, hy),
      Paint()
        ..color = A.petalA.withValues(alpha: 0.85 * k)
        ..strokeWidth = 2,
    );

    // 俯仰刻度梯：每 10° 一条短横线
    final ladderPaint = Paint()
      ..color = T.fg.withValues(alpha: 0.30 * k)
      ..strokeWidth = 1;
    for (var deg = -20; deg <= 20; deg += 10) {
      if (deg == 0) continue;
      final y = hy - deg * 2.2;
      final half = deg.abs() == 10 ? 13.0 : 22.0;
      canvas.drawLine(
        Offset(-half, y),
        Offset(half, y),
        ladderPaint,
      );
    }
    canvas.restore();

    // 中心准星（不随 roll 转）
    final crossPaint = Paint()
      ..color = A.petalA.withValues(alpha: 0.9)
      ..strokeWidth = 1.4;
    canvas.drawLine(c + const Offset(-9, 0), c + const Offset(-3, 0), crossPaint);
    canvas.drawLine(c + const Offset(3, 0), c + const Offset(9, 0), crossPaint);
    canvas.drawLine(c + const Offset(0, -3), c + const Offset(0, 3), crossPaint);

    // 外环
    canvas.drawCircle(
      c,
      r - 1,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.4
        ..color = A.petalB.withValues(alpha: 0.45),
    );

    // 顶部 yaw 指针：沿圆周一个小三角
    final a = -math.pi / 2 + (yaw.clamp(-60.0, 60.0) * math.pi / 180) * 0.5;
    final p = c + Offset(math.cos(a) * (r - 5), math.sin(a) * (r - 5));
    canvas.drawCircle(p, 2.4, Paint()..color = T.sky);
  }

  @override
  bool shouldRepaint(covariant _HorizonPainter old) =>
      old.yaw != yaw ||
      old.pitch != pitch ||
      old.roll != roll ||
      old.tracking != tracking;
}

// =============================================================== 悬浮操作盘

/// 右下角悬浮操作盘：一个圆盘 + 三层同心环，点一下是主操作。
/// 它不是底部导航条 —— 导航在左侧书脊上，这里只放"当下最该按的那一下"。
class FloatingDial extends StatelessWidget {
  const FloatingDial({
    super.key,
    required this.label,
    required this.sublabel,
    required this.onTap,
    required this.live,
    this.busy = false,
  });

  final String label;
  final String sublabel;
  final VoidCallback onTap;
  final bool live;
  final bool busy;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: busy ? null : onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 300),
        width: 84,
        height: 84,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          gradient: live
              ? null
              : const LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: A.btnGrad,
                ),
          color: live ? A.petalB.withValues(alpha: 0.13) : null,
          border: Border.all(
            color: live
                ? A.petalB.withValues(alpha: 0.72)
                : A.petalA.withValues(alpha: 0.95),
            width: live ? 1.6 : 1.4,
          ),
          boxShadow: live
              ? T.glow(A.petalB, blur: 26, alpha: 0.34)
              : [
                  BoxShadow(
                    color: A.petalB.withValues(alpha: 0.52),
                    blurRadius: 28,
                  ),
                  BoxShadow(
                    color: T.wisteriaDeep.withValues(alpha: 0.34),
                    blurRadius: 42,
                    spreadRadius: -4,
                  ),
                ],
        ),
        child: Center(
          child: busy
              ? SizedBox(
                  width: 17,
                  height: 17,
                  child: CircularProgressIndicator(
                    strokeWidth: 1.7,
                    color: live ? A.petalB : T.ink,
                  ),
                )
              : Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      label,
                      style: ts(
                        13,
                        color: live ? A.petalA : T.ink,
                        ls: 1.8,
                        weight: FontWeight.w700,
                        height: 1.1,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      sublabel,
                      style: tm(
                        6.5,
                        color: live
                            ? A.petalB.withValues(alpha: 0.75)
                            : T.ink.withValues(alpha: 0.62),
                        ls: 0.4,
                      ),
                    ),
                  ],
                ),
        ),
      ),
    );
  }
}

// =============================================================== 小配件

/// 竖标：左侧一条渐隐竖线 + 竖排文字（模块内部的小分组标记）。
class VertRule extends StatelessWidget {
  const VertRule(this.text, {super.key});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        children: [
          Container(
            width: 1.5,
            height: 10,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(1),
              color: A.petalB.withValues(alpha: 0.55),
            ),
          ),
          const SizedBox(width: 6),
          Text(text, style: tm(7.5, color: A.petalB, ls: 1.6)),
        ],
      ),
    );
  }
}

/// 迷你开关：一个横向胶囊，开启时内部两段色带亮起（不是圆钮滑块）。
class ChipSwitch extends StatelessWidget {
  const ChipSwitch({super.key, required this.value, required this.onChanged});

  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () => onChanged(!value),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 260),
        width: 40,
        height: 22,
        decoration: BoxDecoration(
          color: value ? null : T.wisteria.withValues(alpha: 0.08),
          gradient: value
              ? const LinearGradient(colors: A.btnGrad)
              : null,
          borderRadius: BorderRadius.circular(6),
          border: Border.all(
            color: value
                ? A.petalB.withValues(alpha: 0.72)
                : T.wisteria.withValues(alpha: 0.18),
          ),
          boxShadow: value ? T.glow(A.petalB, blur: 12, alpha: 0.35) : null,
        ),
        child: Center(
          child: AnimatedAlign(
            duration: const Duration(milliseconds: 260),
            curve: Curves.easeOut,
            alignment: value ? Alignment.centerRight : Alignment.centerLeft,
            child: Container(
              margin: const EdgeInsets.symmetric(horizontal: 3),
              width: 16,
              height: 16,
              decoration: BoxDecoration(
                color: value ? T.ink : const Color(0xFF6B5F8C),
                borderRadius: BorderRadius.circular(3),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 双行按钮（替代 MainButton/SecButton 的窄版）。
class BarButton extends StatelessWidget {
  const BarButton({
    super.key,
    required this.label,
    required this.onTap,
    this.icon,
    this.enabled = true,
    this.tinted = false,
  });

  final String label;
  final VoidCallback? onTap;
  final Ico? icon;
  final bool enabled;
  final bool tinted;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: enabled ? onTap : null,
      child: AnimatedOpacity(
        duration: const Duration(milliseconds: 220),
        opacity: enabled ? 1 : 0.40,
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 9, horizontal: 10),
          decoration: BoxDecoration(
            gradient: tinted && enabled
                ? LinearGradient(
                    colors: [
                      A.petalB.withValues(alpha: 0.18),
                      T.wisteria.withValues(alpha: 0.10),
                    ],
                  )
                : null,
            color: tinted ? null : T.wisteria.withValues(alpha: 0.07),
            borderRadius: BorderRadius.circular(11),
            border: Border.all(
              color: enabled
                  ? (tinted
                      ? A.petalB.withValues(alpha: 0.48)
                      : T.wisteria.withValues(alpha: 0.20))
                  : T.wisteria.withValues(alpha: 0.10),
            ),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              if (icon != null) ...[
                LineIcon(
                  icon!,
                  size: 12,
                  stroke: 1.5,
                  color: enabled ? A.petalA : T.faint,
                ),
                const SizedBox(width: 5),
              ],
              Flexible(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: ts(
                    10,
                    ls: 0.5,
                    color: enabled ? T.fg : T.dim,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
