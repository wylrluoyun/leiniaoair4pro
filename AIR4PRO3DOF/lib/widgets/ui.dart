import 'package:flutter/material.dart';

import '../theme/app_theme.dart';
import 'anime.dart';
import 'icons.dart';

/// ---------------------------------------------------------------------------
/// 界面原子组件 —「夜桜」二次元版本
///
/// 与旧版（极简黑白）的区别，但**API 签名全部不变**，页面零改动即换皮：
///  · 页头：霓虹竖条 + 发光大标题 + 可选副标题
///  · 卡片：渐变霓虹描边 + 紫调实底 + 外发光（赛璐璐感）
///  · 按钮：樱花→紫藤渐变 + 光晕
///  · 状态：实色块 + 霓虹描边 + 脉动光点
///  · 分隔线：紫藤色（白线在深紫底上会显脏）
/// ---------------------------------------------------------------------------

// =============================================================== 页面骨架

/// 页头（霓虹竖条 + 发光标题 + 状态胶囊）与可滚动正文。
///
/// v2 重排：现在页面装在左侧窄面板里（约屏宽 62%），不再是整屏宽度。
///  · maxWidth 从 560 降到 460，避免在平板/横屏上被拉成一条
///  · 右侧预留 44px 给竖排圆形导航，否则内容会被导航钮压住
///  · 页头改纵向紧凑型（标题在上、胶囊在下），窄面板里横排会挤爆
class PageShell extends StatelessWidget {
  const PageShell({
    super.key,
    required this.eyebrow,
    required this.title,
    required this.pill,
    required this.children,
    this.subtitle,
  });

  final String eyebrow;
  final String title;
  final Widget pill;
  final List<Widget> children;
  final String? subtitle;

  /// 竖排导航占据的右缘宽度。所有页面统一预留，避免内容跑到导航钮下面。
  static const railGutter = 52.0;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 460),
        child: _body(context),
      ),
    );
  }

  Widget _body(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SafeArea(
          bottom: false,
          child: Padding(
            padding: EdgeInsets.fromLTRB(
              T.pad,
              10,
              T.pad + railGutter,
              14,
            ),
            child: AnimeHeader(
              eyebrow: eyebrow,
              title: title,
              pill: pill,
              subtitle: subtitle,
            ),
          ),
        ),
        Expanded(
          child: SingleChildScrollView(
            padding: EdgeInsets.fromLTRB(
              T.pad,
              0,
              T.pad + railGutter,
              28,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: children,
            ),
          ),
        ),
      ],
    );
  }
}

/// 状态胶囊：待机 / 启动中 / 运行中 / 需处理。
/// 用实色块 + 同色霓虹描边 + 光晕；运行中是薄荷绿，异常是樱花红。
class StatusPill extends StatelessWidget {
  const StatusPill({
    super.key,
    required this.running,
    required this.starting,
    this.error = false,
  });

  final bool running;
  final bool starting;
  final bool error;

  @override
  Widget build(BuildContext context) {
    final label = error
        ? '需处理'
        : running
            ? '运行中'
            : starting
                ? '启动中'
                : '待机';
    final tint = error
        ? T.red
        : running
            ? T.mint
            : starting
                ? T.amber
                : T.faint;
    final lit = running || error;
    return AnimatedContainer(
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeOut,
      padding: const EdgeInsets.fromLTRB(11, 6, 12, 6),
      decoration: BoxDecoration(
        color: tint.withValues(alpha: lit ? 0.18 : 0.07),
        borderRadius: BorderRadius.circular(A.rPill),
        border: Border.all(
          color: tint.withValues(alpha: lit ? 0.66 : 0.28),
          width: 1.2,
        ),
        boxShadow: lit ? T.glow(tint, blur: 16, alpha: 0.35) : null,
      ),
      child: MediaQuery.withClampedTextScaling(
        maxScaleFactor: 1.2,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            PulseDot(live: running, color: tint),
            const SizedBox(width: 6),
            Text(
              label,
              style: tm(
                9,
                color: lit ? tint : T.dim,
                ls: 1.6,
                weight: FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 4px 状态点：运行时脉动 + 同色辉光。
class PulseDot extends StatefulWidget {
  const PulseDot({
    super.key,
    required this.live,
    this.size = 4,
    this.color = T.mint,
  });

  final bool live;
  final double size;
  final Color color;

  @override
  State<PulseDot> createState() => _PulseDotState();
}

class _PulseDotState extends State<PulseDot>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 2000),
  )..repeat(reverse: true);

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final dot = Container(
      width: widget.size,
      height: widget.size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: widget.live ? widget.color : T.faint,
        boxShadow: widget.live
            ? [
                BoxShadow(
                  color: widget.color.withValues(alpha: 0.85),
                  blurRadius: 10,
                ),
              ]
            : null,
      ),
    );
    if (!widget.live) return dot;
    return FadeTransition(
      opacity: Tween<double>(begin: 1, end: 0.22).animate(
        CurvedAnimation(parent: _c, curve: Curves.easeInOut),
      ),
      child: dot,
    );
  }
}

// =============================================================== 分组

/// 分组标题：樱花粉小字 + 前置星点 + 渐隐霓虹线。
class GroupLabel extends StatelessWidget {
  const GroupLabel(this.text, {super.key, this.first = false});

  final String text;
  final bool first;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(top: first ? 2 : 22, bottom: 11),
      child: MediaQuery.withClampedTextScaling(
        maxScaleFactor: 1.2,
        child: Row(
          children: [
            Container(
              width: 4,
              height: 4,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: A.petalB,
                boxShadow: T.glow(A.petalB, blur: 9, alpha: 0.75),
              ),
            ),
            const SizedBox(width: 8),
            Text(
              text.toUpperCase(),
              style: tm(9, color: A.petalB, ls: 2.34, weight: FontWeight.w600),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Container(
                height: 1,
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    colors: [T.lineSakura, T.wisteria.withValues(alpha: 0)],
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 分组列表卡：渐变霓虹描边 + 紫调底，行间紫藤发丝线。
class GroupCard extends StatelessWidget {
  const GroupCard({super.key, required this.children, this.color = T.card});

  final List<Widget> children;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return CelCard(
      padding: EdgeInsets.zero,
      fill: color,
      grad: const [A.petalB, T.wisteria, T.sky],
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (var i = 0; i < children.length; i++) ...[
            children[i],
            if (i != children.length - 1)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 14),
                child: Container(height: 1, color: T.hair2),
              ),
          ],
        ],
      ),
    );
  }
}

/// 通用行：标签（+可选代码标签/说明）+ 右侧值 / 尾部控件 / 箭头。
class HairRow extends StatelessWidget {
  const HairRow({
    super.key,
    required this.label,
    this.code,
    this.sub,
    this.subDot,
    this.value,
    this.trailing,
    this.leading,
    this.onTap,
    this.padding = const EdgeInsets.fromLTRB(16, 14, 16, 14),
  });

  final String label;
  final String? code;
  final String? sub;

  /// 说明行前的小圆点：true=实心带辉光，false=空心描边（无障碍/Shizuku 的开关态）
  final bool? subDot;
  final String? value;
  final Widget? trailing;
  final Widget? leading;
  final VoidCallback? onTap;
  final EdgeInsets padding;

  @override
  Widget build(BuildContext context) {
    final body = Padding(
      padding: padding,
      child: Row(
        children: [
          if (leading != null) ...[leading!, const SizedBox(width: 13)],
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Flexible(
                      child: Text(
                        label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: ts(13.5, ls: 0.4),
                      ),
                    ),
                    if (code != null) ...[
                      const SizedBox(width: 6),
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 5,
                          vertical: 1,
                        ),
                        decoration: BoxDecoration(
                          color: T.wisteria.withValues(alpha: 0.15),
                          borderRadius: BorderRadius.circular(5),
                        ),
                        child: Text(
                          code!,
                          style: tm(9, color: T.wisteria, ls: 0.6),
                        ),
                      ),
                    ],
                  ],
                ),
                if (sub != null) ...[
                  const SizedBox(height: 5),
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (subDot != null) ...[
                        Padding(
                          padding: const EdgeInsets.only(top: 5),
                          child: Container(
                            width: 5,
                            height: 5,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              color: subDot! ? T.mint : Colors.transparent,
                              border: subDot!
                                  ? null
                                  : Border.all(color: T.faint, width: 1),
                              boxShadow: subDot!
                                  ? T.glow(T.mint, blur: 8, alpha: 0.8)
                                  : null,
                            ),
                          ),
                        ),
                        const SizedBox(width: 5),
                      ],
                      Expanded(
                        child: Text(
                          sub!,
                          style:
                              ts(10.5, color: T.faint, height: 1.55, ls: 0.2),
                        ),
                      ),
                    ],
                  ),
                ],
              ],
            ),
          ),
          if (value != null) ...[
            const SizedBox(width: 14),
            Text(value!, style: tm(12, color: T.dim)),
          ],
          if (trailing != null) ...[
            const SizedBox(width: 12),
            trailing!,
          ],
          if (onTap != null && trailing == null) ...[
            const SizedBox(width: 6),
            LineIcon(icoChevron, size: 14, color: T.arrow),
          ],
        ],
      ),
    );
    if (onTap == null) return body;
    return Material(
      color: Colors.transparent,
      child: InkWell(onTap: onTap, child: body),
    );
  }
}

/// 开关行：整行可点。
class ToggleRow extends StatelessWidget {
  const ToggleRow({
    super.key,
    required this.label,
    this.code,
    this.sub,
    required this.value,
    required this.onChanged,
    this.enabled = true,
  });

  final String label;
  final String? code;
  final String? sub;
  final bool value;
  final ValueChanged<bool> onChanged;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    return HairRow(
      label: label,
      code: code,
      sub: sub,
      onTap: enabled ? () => onChanged(!value) : null,
      trailing: HairSwitch(value: value),
    );
  }
}

/// 42×24 胶囊开关：开启是樱花→紫藤渐变 + 光晕，关闭是暗紫底 + 灰钮。
class HairSwitch extends StatelessWidget {
  const HairSwitch({super.key, required this.value});

  final bool value;

  @override
  Widget build(BuildContext context) {
    return AnimatedContainer(
      duration: const Duration(milliseconds: 280),
      curve: const Cubic(0.2, 0.8, 0.2, 1),
      width: 42,
      height: 24,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(14),
        gradient: value
            ? const LinearGradient(colors: A.btnGrad)
            : null,
        color: value ? null : T.wisteria.withValues(alpha: 0.10),
        border: Border.all(
          color: value
              ? A.petalB.withValues(alpha: 0.75)
              : T.wisteria.withValues(alpha: 0.22),
        ),
        boxShadow: value ? T.glow(A.petalB, blur: 14, alpha: 0.45) : null,
      ),
      child: Stack(
        children: [
          AnimatedPositioned(
            duration: const Duration(milliseconds: 280),
            curve: const Cubic(0.2, 0.8, 0.2, 1),
            top: 2.5,
            left: value ? 20.5 : 2.5,
            child: Container(
              width: 17,
              height: 17,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: value ? T.ink : const Color(0xFF6B5F8C),
                boxShadow: value
                    ? [
                        BoxShadow(
                          color: Colors.black.withValues(alpha: 0.35),
                          blurRadius: 3,
                        ),
                      ]
                    : null,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 分段控件：选中是樱花色渐变实底 + 光晕，关闭时整体降到 45% 不透明度。
class SegRow extends StatelessWidget {
  const SegRow({
    super.key,
    required this.items,
    required this.index,
    this.onChanged,
    this.enabled = true,
  });

  final List<String> items;
  final int index;
  final ValueChanged<int>? onChanged;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    return AnimatedOpacity(
      duration: const Duration(milliseconds: 300),
      opacity: enabled ? 1 : 0.45,
      child: Container(
        padding: const EdgeInsets.all(3),
        decoration: BoxDecoration(
          color: T.wisteria.withValues(alpha: 0.06),
          borderRadius: BorderRadius.circular(T.rSeg),
          border: Border.all(color: T.hair1),
        ),
        child: MediaQuery.withClampedTextScaling(
          maxScaleFactor: 1.15,
          child: Row(
            children: [
              for (var i = 0; i < items.length; i++)
                Expanded(
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: enabled && onChanged != null
                        ? () => onChanged!(i)
                        : null,
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 250),
                      curve: Curves.easeOut,
                      padding: const EdgeInsets.symmetric(vertical: 10),
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(10),
                        gradient: i == index
                            ? const LinearGradient(
                                colors: [
                                  Color(0x4DFF9CCB),
                                  Color(0x33C39BFF),
                                ],
                              )
                            : null,
                        border: i == index
                            ? Border.all(
                                color: A.petalB.withValues(alpha: 0.55),
                              )
                            : null,
                        boxShadow: i == index
                            ? T.glow(A.petalB, blur: 12, alpha: 0.22)
                            : null,
                      ),
                      child: Center(
                        child: Text(
                          items[i],
                          maxLines: 1,
                          softWrap: false,
                          style: tm(
                            10.5,
                            color: i == index ? A.petalA : T.faint,
                            ls: 0.85,
                            weight:
                                i == index ? FontWeight.w600 : FontWeight.w400,
                            height: 1.2,
                          ),
                        ),
                      ),
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

// =============================================================== 滑块

/// 2px 轨道 + 13px 白光圆钮。拖到哪算到哪，按 divisions 吸附。
class HairSlider extends StatelessWidget {
  const HairSlider({
    super.key,
    required this.value,
    required this.min,
    required this.max,
    required this.onChanged,
    this.divisions,
    this.enabled = true,
  });

  final double value;
  final double min;
  final double max;
  final int? divisions;
  final ValueChanged<double> onChanged;
  final bool enabled;

  void _emit(double dx, double width) {
    const thumb = 13.0;
    final travel = (width - thumb).clamp(1.0, double.infinity);
    var t = ((dx - thumb / 2) / travel).clamp(0.0, 1.0);
    var v = min + t * (max - min);
    if (divisions != null && divisions! > 0) {
      final step = (max - min) / divisions!;
      v = (v / step).roundToDouble() * step;
    }
    onChanged(v.clamp(min, max));
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, box) {
        final w = box.maxWidth;
        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTapDown: enabled ? (d) => _emit(d.localPosition.dx, w) : null,
          onHorizontalDragStart:
              enabled ? (d) => _emit(d.localPosition.dx, w) : null,
          onHorizontalDragUpdate:
              enabled ? (d) => _emit(d.localPosition.dx, w) : null,
          child: SizedBox(
            height: 24,
            width: double.infinity,
            child: CustomPaint(
              painter: _SliderPainter(
                t: ((value - min) / (max - min)).clamp(0.0, 1.0),
                enabled: enabled,
              ),
            ),
          ),
        );
      },
    );
  }
}

class _SliderPainter extends CustomPainter {
  _SliderPainter({required this.t, required this.enabled});

  final double t;
  final bool enabled;

  @override
  void paint(Canvas canvas, Size size) {
    const thumb = 7.5;
    final y = size.height / 2;
    final x0 = thumb;
    final x1 = size.width - thumb;
    final k = enabled ? 1.0 : 0.4;

    // 轨道：暗紫
    canvas.drawLine(
      Offset(x0, y),
      Offset(x1, y),
      Paint()
        ..color = T.wisteria.withValues(alpha: 0.14 * k)
        ..strokeWidth = 2.5
        ..strokeCap = StrokeCap.round,
    );

    final px = x0 + (x1 - x0) * t;

    // 已走过的一段：樱花→紫藤渐变
    canvas.drawLine(
      Offset(x0, y),
      Offset(px, y),
      Paint()
        ..strokeWidth = 2.5
        ..strokeCap = StrokeCap.round
        ..shader = const LinearGradient(
          colors: [A.petalC, A.petalB, T.wisteria],
        ).createShader(Rect.fromLTRB(x0, y - 2, x1, y + 2)),
    );

    if (enabled) {
      // 圆钮外圈光晕
      canvas.drawCircle(
        Offset(px, y),
        thumb + 7,
        Paint()
          ..color = A.petalB.withValues(alpha: 0.22)
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 7),
      );
    }
    // 圆钮：亮樱花，带细描边
    canvas.drawCircle(
      Offset(px, y),
      thumb,
      Paint()..color = A.petalA.withValues(alpha: k),
    );
    canvas.drawCircle(
      Offset(px, y),
      thumb,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.2
        ..color = A.petalC.withValues(alpha: 0.9 * k),
    );
  }

  @override
  bool shouldRepaint(covariant _SliderPainter old) =>
      old.t != t || old.enabled != enabled;
}

/// 带标题与读数的滑块块：`尺寸 ————————— 1.20×`。
class SliderBlock extends StatelessWidget {
  const SliderBlock({
    super.key,
    required this.label,
    required this.readout,
    required this.value,
    required this.min,
    required this.max,
    required this.onChanged,
    this.divisions,
    this.enabled = true,
    this.padding = const EdgeInsets.fromLTRB(16, 14, 16, 10),
    this.border = true,
  });

  final String label;
  final String readout;
  final double value;
  final double min;
  final double max;
  final int? divisions;
  final ValueChanged<double> onChanged;
  final bool enabled;
  final EdgeInsets padding;
  final bool border;

  @override
  Widget build(BuildContext context) {
    final content = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        MediaQuery.withClampedTextScaling(
          maxScaleFactor: 1.2,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: [
              Expanded(child: Text(label, style: ts(13.5, ls: 0.4))),
              Text(
                readout,
                style: tm(
                  12,
                  color: enabled ? T.fg : T.faint,
                  weight: FontWeight.w400,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 4),
        HairSlider(
          value: value,
          min: min,
          max: max,
          divisions: divisions,
          onChanged: onChanged,
          enabled: enabled,
        ),
      ],
    );
    if (!border) return Padding(padding: padding, child: content);
    return Padding(padding: padding, child: content);
  }
}

/// 色彩胶囊：小圆点 + 名称，选中时描边变亮、底色加深。
class ColorChip extends StatelessWidget {
  const ColorChip({
    super.key,
    required this.label,
    required this.swatch,
    required this.selected,
    required this.onTap,
    this.padding = const EdgeInsets.symmetric(horizontal: 13, vertical: 8),
  });

  final String label;
  final Color swatch;
  final bool selected;
  final VoidCallback onTap;
  final EdgeInsets padding;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 250),
        padding: padding,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(T.rChip),
          color: selected
              ? A.petalB.withValues(alpha: 0.16)
              : T.wisteria.withValues(alpha: 0.06),
          border: Border.all(
            color: selected ? A.petalB.withValues(alpha: 0.75) : T.hair1,
          ),
          boxShadow: selected ? T.glow(A.petalB, blur: 14, alpha: 0.32) : null,
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 7,
              height: 7,
              decoration: BoxDecoration(
                color: swatch,
                shape: BoxShape.circle,
                boxShadow: selected ? T.glow(swatch, blur: 9, alpha: 0.8) : null,
              ),
            ),
            const SizedBox(width: 7),
            Text(
              label,
              style: ts(11.5, color: selected ? T.fg : T.dim, ls: 0.9),
            ),
          ],
        ),
      ),
    );
  }
}

// =============================================================== 按钮

/// 主操作：樱花→紫藤渐变 + 光晕；运行中退成樱花描边。
class MainButton extends StatelessWidget {
  const MainButton({
    super.key,
    required this.label,
    required this.onPressed,
    this.stop = false,
    this.busy = false,
  });

  final String label;
  final VoidCallback? onPressed;
  final bool stop;
  final bool busy;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: busy ? null : onPressed,
      child: AnimatedOpacity(
        duration: const Duration(milliseconds: 200),
        opacity: busy ? 0.55 : 1,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 280),
          curve: Curves.easeOut,
          padding: const EdgeInsets.symmetric(vertical: 17),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(T.rBtn),
            gradient: stop
                ? null
                : const LinearGradient(
                    begin: Alignment.centerLeft,
                    end: Alignment.centerRight,
                    colors: A.btnGrad,
                  ),
            color: stop ? A.petalB.withValues(alpha: 0.10) : null,
            border: Border.all(
              color: stop
                  ? A.petalB.withValues(alpha: 0.62)
                  : A.petalA.withValues(alpha: 0.85),
              width: stop ? 1.4 : 1.2,
            ),
            boxShadow: stop
                ? T.glow(A.petalB, blur: 18, alpha: 0.22)
                : [
                    BoxShadow(
                      color: A.petalB.withValues(alpha: 0.42),
                      blurRadius: 26,
                      offset: const Offset(0, 4),
                    ),
                    BoxShadow(
                      color: T.wisteriaDeep.withValues(alpha: 0.26),
                      blurRadius: 40,
                      spreadRadius: -6,
                    ),
                  ],
          ),
          child: MediaQuery.withClampedTextScaling(
            maxScaleFactor: 1.2,
            child: Center(
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (busy) ...[
                    SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(
                        strokeWidth: 1.6,
                        color: stop ? A.petalB : T.ink,
                      ),
                    ),
                    const SizedBox(width: 10),
                  ],
                  Text(
                    label,
                    style: ts(
                      14,
                      color: stop ? A.petalA : T.ink,
                      ls: 2.7,
                      weight: FontWeight.w700,
                      height: 1.2,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 次操作：霓虹细描边 + 图标。
class SecButton extends StatelessWidget {
  const SecButton({
    super.key,
    required this.label,
    required this.onPressed,
    this.icon,
  });

  final String label;
  final VoidCallback? onPressed;
  final Ico? icon;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onPressed,
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 13, horizontal: 8),
        decoration: BoxDecoration(
          color: T.wisteria.withValues(alpha: 0.09),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: T.lineSakura),
          boxShadow: T.glow(T.wisteriaDeep, blur: 14, alpha: 0.16),
        ),
        child: MediaQuery.withClampedTextScaling(
          maxScaleFactor: 1.2,
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              if (icon != null) ...[
                LineIcon(icon!, size: 14, stroke: 1.5, color: A.petalA),
                const SizedBox(width: 7),
              ],
              Flexible(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: ts(12.5, ls: 0.75, color: T.fg),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 行内小按钮（系统页的"设置 / 管理"）。
class MiniButton extends StatelessWidget {
  const MiniButton({super.key, required this.label, this.onPressed});

  final String label;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onPressed,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(T.rMini),
          border: Border.all(color: T.hair(0.18)),
        ),
        child: Text(label, style: tm(9.5, color: T.fg, ls: 1.15)),
      ),
    );
  }
}

// =============================================================== 文本

class Hint extends StatelessWidget {
  const Hint(this.text, {super.key, this.top = 9});

  final String text;
  final double top;

  @override
  Widget build(BuildContext context) => Padding(
        padding: EdgeInsets.fromLTRB(2, top, 2, 0),
        child: Text(text, style: ts(10.5, color: T.faint, height: 1.7, ls: 0.2)),
      );
}

class Desc extends StatelessWidget {
  const Desc(this.text, {super.key});

  final String text;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(2, 10, 2, 0),
        child: Text(text, style: ts(11, color: T.dim, height: 1.75, ls: 0.3)),
      );
}

class FootNote extends StatelessWidget {
  const FootNote(this.text, {super.key});

  final String text;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(top: 22, bottom: 6),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              width: 5,
              height: 5,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: A.petalB.withValues(alpha: 0.55),
                boxShadow: T.glow(A.petalB, blur: 8, alpha: 0.5),
              ),
            ),
            const SizedBox(width: 8),
            Flexible(
              child: Text(
                text,
                textAlign: TextAlign.center,
                style: tm(8.5, color: T.faint, ls: 1.5, height: 2),
              ),
            ),
            const SizedBox(width: 8),
            Container(
              width: 5,
              height: 5,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: A.petalB.withValues(alpha: 0.55),
                boxShadow: T.glow(A.petalB, blur: 8, alpha: 0.5),
              ),
            ),
          ],
        ),
      );
}

/// 状态行（投屏模式下方的一行提示：图标 + 一句话）
class StateLine extends StatelessWidget {
  const StateLine({
    super.key,
    required this.text,
    required this.live,
  });

  final String text;
  final bool live;

  @override
  Widget build(BuildContext context) {
    final color = live ? T.fg : T.faint;
    return Padding(
      padding: const EdgeInsets.fromLTRB(2, 11, 2, 0),
      child: Row(
        children: [
          LineIcon(live ? icoCheck : icoInfo, size: 13, color: color, stroke: 1.6),
          const SizedBox(width: 7),
          Expanded(
            child: Text(
              text,
              style: ts(10.5, color: color, ls: 0.3, height: 1.4),
            ),
          ),
        ],
      ),
    );
  }
}

// =============================================================== 指标

/// 状态卡里的三格读数（帧 / 姿态 / 捕获）。
class MetricStrip extends StatelessWidget {
  const MetricStrip({super.key, required this.items, required this.live});

  final List<(String, String)> items;
  final bool live;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        border: Border(top: BorderSide(color: T.hair2)),
      ),
      child: MediaQuery.withClampedTextScaling(
        maxScaleFactor: 1.2,
        child: Row(
          children: [
            for (var i = 0; i < items.length; i++)
              Expanded(
                child: Container(
                  padding: const EdgeInsets.fromLTRB(0, 12, 0, 14),
                  decoration: BoxDecoration(
                    border: i == items.length - 1
                        ? null
                        : Border(right: BorderSide(color: T.hair2)),
                  ),
                  child: Column(
                    children: [
                      Text(items[i].$1, style: tm(8, ls: 1.6)),
                      const SizedBox(height: 7),
                      Text(
                        items[i].$2,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: tm(12.5, color: live ? T.fg : T.dim, ls: 0.2),
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

/// 会话摘要四格（模式 / 尺寸 / 距离 / 视场角）。
class SumStrip extends StatelessWidget {
  const SumStrip({super.key, required this.items});

  final List<(String, String)> items;

  @override
  Widget build(BuildContext context) {
    return CelCard(
      padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 4),
      grad: const [T.wisteria, T.sky, T.wisteria],
      glow: false,
      fill: T.wisteria.withValues(alpha: 0.05),
      child: MediaQuery.withClampedTextScaling(
        maxScaleFactor: 1.2,
        child: Row(
          children: [
            for (var i = 0; i < items.length; i++)
              Expanded(
                child: Container(
                  decoration: BoxDecoration(
                    border: i == items.length - 1
                        ? null
                        : Border(right: BorderSide(color: T.hair2)),
                  ),
                  child: Column(
                    children: [
                      Text(
                        items[i].$1,
                        style: tm(8, color: T.faint, ls: 1.44),
                      ),
                      const SizedBox(height: 7),
                      Text(
                        items[i].$2,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: tm(11.5, color: A.petalA, ls: 0.2),
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

/// 诊断表：左侧 64dp 标签 + 右侧等宽值。
class DiagRow extends StatelessWidget {
  const DiagRow({super.key, required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 9),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 64,
            child: Text(label, style: ts(10.5, color: T.faint, ls: 0.6)),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Text(
              value,
              style: tm(10, color: T.dim, height: 1.6),
            ),
          ),
        ],
      ),
    );
  }
}

/// 诊断容器：霓虹描边 + 紫调底，内部行间紫藤发丝线。
class DiagCard extends StatelessWidget {
  const DiagCard({super.key, required this.rows});

  final List<(String, String)> rows;

  @override
  Widget build(BuildContext context) {
    return CelCard(
      padding: const EdgeInsets.fromLTRB(16, 6, 16, 6),
      grad: const [T.wisteria, T.sky, T.wisteria],
      glow: false,
      fill: T.wisteria.withValues(alpha: 0.04),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (var i = 0; i < rows.length; i++) ...[
            DiagRow(label: rows[i].$1, value: rows[i].$2),
            if (i != rows.length - 1) Container(height: 1, color: T.hair2),
          ],
        ],
      ),
    );
  }
}

// =============================================================== 动效

/// 入场：淡入 + 上移 9px + 轻微缩放，按序号错峰。纯一次性动画，不打乱布局。
class RiseIn extends StatefulWidget {
  const RiseIn({super.key, required this.index, required this.child});

  final int index;
  final Widget child;

  @override
  State<RiseIn> createState() => _RiseInState();
}

class _RiseInState extends State<RiseIn> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 460),
  );
  late final Animation<double> _t = CurvedAnimation(
    parent: _c,
    // 二次元常见的那条「快速起、柔和收」的缓动
    curve: const Cubic(0.16, 0.84, 0.28, 1),
  );

  @override
  void initState() {
    super.initState();
    final delay = Duration(milliseconds: 20 + widget.index * 55);
    Future<void>.delayed(delay, () {
      if (mounted) _c.forward();
    });
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _t,
      builder: (context, child) {
        final v = _t.value.clamp(0.0, 1.0);
        return Opacity(
          opacity: v,
          child: Transform.translate(
            offset: Offset(0, (1 - v) * 14),
            child: Transform.scale(
              scale: 0.97 + v * 0.03,
              child: child,
            ),
          ),
        );
      },
      child: widget.child,
    );
  }
}
