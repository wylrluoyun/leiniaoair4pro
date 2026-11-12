import 'package:flutter/material.dart';

import '../engine/engine_client.dart';
import '../theme/app_theme.dart';
import '../widgets/anime.dart';
import '../widgets/icons.dart';
import '../widgets/ui.dart';

/// 概览页 ——「夜桜」v2 重排
///
/// 与 v1 的结构差异（真重排，不是挪几个像素）：
///  v1：状态卡（含空间预览）→ 大按钮 → 次按钮 → 四格摘要
///      —— 一条竖向流水线，最重要的"开始投屏"被压在下面
///  v2：**顶部状态条（一行胶囊 + 帧数）** → **辐条式环形表盘**（姿态/帧/捕获
///      三项读数排成环形，正中是主操作按钮）→ 快捷操作改成**两列宫格**
///      → 底部参数条。主操作从"第 3 个看到的"提到"视线正中"。
class OverviewPage extends StatelessWidget {
  const OverviewPage({
    super.key,
    required this.engine,
    required this.onOpenPad,
  });

  final EngineModel engine;
  final VoidCallback onOpenPad;

  static String _viewLabel(String v) => switch (v) {
        'track' => '追踪',
        'extend' => '扩展',
        _ => '悬停',
      };

  @override
  Widget build(BuildContext context) {
    final s = engine.status;
    final c = engine.config ?? const EngineConfig();
    final sizeText = '${(0.3 + c.size / 100).toStringAsFixed(2)}×';
    final distText = '${(1 + c.distance / 10).toStringAsFixed(1)} m';
    final fovText = '${15 + c.fov}°';
    final live = s.running;

    return PageShell(
      eyebrow: 'Yozakura · ①',
      title: '悬停',
      subtitle: !s.glasses
          ? '请确认已插好眼镜，手机需支持 USB-C DP 输出'
          : live
              ? '${s.hosted ? '扩展屏运行中' : '镜像投屏中'}　·　${_viewLabel(c.viewMode)}模式'
              : '眼镜已连接：${s.displayName}',
      pill: StatusPill(
        running: s.running,
        starting: s.starting,
        error: engine.lastError != null,
      ),
      children: [
        if (engine.lastError != null)
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: _errorStrip(engine.lastError!),
          ),

        // ── 主视觉：环形表盘 + 中心主按钮
        RiseIn(
          index: 0,
          child: _DialCard(
            engine: engine,
            status: s,
            live: live,
            onOpenPad: onOpenPad,
          ),
        ),

        const SizedBox(height: 14),

        // ── 快捷操作：两列宫格（原是横排一行，窄面板里挤不下）
        RiseIn(
          index: 1,
          child: Row(
            children: [
              Expanded(
                child: _ActionTile(
                  icon: icoRecenter,
                  label: '画面复位',
                  hint: '回正前方',
                  onTap: engine.recenter,
                  enabled: live,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: _ActionTile(
                  icon: icoTouchpad,
                  label: '触控板',
                  hint: s.hosted ? '可注入' : '扩展屏专用',
                  onTap: s.hosted ? onOpenPad : null,
                  enabled: s.hosted,
                ),
              ),
            ],
          ),
        ),

        const SizedBox(height: 14),

        // ── 参数：四个小胶囊横向滚动（原是等分四格，窄面板里字会缩小到看不清）
        RiseIn(
          index: 2,
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
                _ParamChip(label: '模式', value: _viewLabel(c.viewMode)),
                const SizedBox(width: 8),
                _ParamChip(label: '尺寸', value: sizeText),
                const SizedBox(width: 8),
                _ParamChip(label: '距离', value: distText),
                const SizedBox(width: 8),
                _ParamChip(label: '视场', value: fovText),
              ],
            ),
          ),
        ),

        const SizedBox(height: 18),
        const Stardust(),
        if (!live) ...[
          const SizedBox(height: 6),
          const Hint('首次会依次请求 USB 与录屏授权；弹窗需要你自己点「允许」和「立即开始」'),
        ],
      ],
    );
  }

  Widget _errorStrip(String message) {
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 11, 8, 11),
      decoration: BoxDecoration(
        color: T.red.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: T.red.withValues(alpha: 0.55), width: 1.2),
        boxShadow: T.glow(T.red, blur: 18, alpha: 0.28),
      ),
      child: Row(
        children: [
          Expanded(
            child: Text(
              message,
              style: ts(10.5, color: const Color(0xFFFFC2CE), height: 1.5),
            ),
          ),
          MiniButton(label: '忽略', onPressed: engine.clearError),
        ],
      ),
    );
  }
}

/// 环形表盘卡片：中间是主操作按钮，四周环绕三项读数。
///
/// 布局取舍：窄面板（约 240px）里放不下"左中右三列读数 + 中间屏幕预览"，
/// 所以把空间预览换成**环绕式读数**——三个小圆点状标签挂在中心按钮四周，
/// 视觉重心落在中心按钮上，这个卡片就成了整页的绝对主角。
class _DialCard extends StatelessWidget {
  const _DialCard({
    required this.engine,
    required this.status,
    required this.live,
    required this.onOpenPad,
  });

  final EngineModel engine;
  final EngineStatus status;
  final bool live;
  final VoidCallback onOpenPad;

  @override
  Widget build(BuildContext context) {
    return CelCard(
      padding: const EdgeInsets.fromLTRB(16, 18, 16, 18),
      grad: live
          ? const [A.petalB, T.wisteria, T.sky]
          : const [T.wisteria, T.sky],
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // 顶部：呼吸 glyph + 标题两行
          Row(
            children: [
              _PulseGlyph(running: live, ok: status.glasses),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    AnimatedSwitcher(
                      duration: const Duration(milliseconds: 240),
                      child: Text(
                        !status.glasses
                            ? '未检测到眼镜'
                            : live
                                ? (status.hosted ? '扩展屏投屏中' : '镜像投屏中')
                                : status.starting
                                    ? '正在启动…'
                                    : '准备就绪',
                        key: ValueKey('$live${status.glasses}'),
                        style: ts(
                          14,
                          ls: 0.5,
                          weight: FontWeight.w700,
                          color: live ? A.petalA : T.fg,
                        ),
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      status.pose.tracking
                          ? '姿态追踪 ${status.pose.hz.toStringAsFixed(0)} Hz'
                          : '等待 IMU 数据…',
                      style: tm(9, color: T.faint, ls: 0.7),
                    ),
                  ],
                ),
              ),
            ],
          ),

          const SizedBox(height: 16),

          // 环形：三项读数 + 中心按钮
          SizedBox(
            height: 168,
            child: Stack(
              alignment: Alignment.center,
              children: [
                // 外圈虚线环（装饰，给"表盘"感）
                Positioned.fill(
                  child: CustomPaint(painter: _RingPainter(live: live)),
                ),
                // 三个读数气泡：帧 / 捕获 / 姿态
                Align(
                  alignment: const Alignment(-1.0, -1.0),
                  child: _Bubble(
                    label: '帧',
                    value: status.frames > 0 ? '${status.frames}' : '—',
                    accent: A.petalA,
                  ),
                ),
                Align(
                  alignment: const Alignment(1.0, -0.62),
                  child: _Bubble(
                    label: '捕获',
                    value: status.capture.w > 0
                        ? '${status.capture.w}×${status.capture.h}'
                        : '—',
                    accent: T.sky,
                  ),
                ),
                Align(
                  alignment: const Alignment(0.72, 1.0),
                  child: _Bubble(
                    label: '姿态',
                    value: status.pose.tracking
                        ? '${status.pose.yaw.toStringAsFixed(0)}°'
                        : '—',
                    accent: T.mint,
                  ),
                ),
                // 中心主按钮（圆形）
                _RoundMainButton(
                  label: status.starting
                      ? '启动中'
                      : live
                          ? '停止'
                          : '开始',
                  busy: status.starting,
                  stop: live,
                  onTap: live ? engine.stop : engine.start,
                ),
              ],
            ),
          ),

          _footerRow(status),
        ],
      ),
    );
  }

  /// 底行：角度读数 + 重新检测（只在没眼镜时出现）
  Widget _footerRow(EngineStatus status) {
    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: Row(
        children: [
          Expanded(
            child: Text(
              status.pose.tracking
                  ? 'yaw ${status.pose.yaw.toStringAsFixed(1)}° · '
                      'pitch ${status.pose.pitch.toStringAsFixed(1)}°'
                  : '—',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: tm(8.5, color: T.faint, ls: 0.6),
            ),
          ),
          if (!status.glasses)
            MiniButton(label: '重新检测', onPressed: engine.refresh),
        ],
      ),
    );
  }
}

/// 环形虚线：外圈 12 段弧，运行时点亮并缓慢旋转（静态渲染时不做旋转，
/// 只按 live 决定颜色，避免 golden 预览每次跑出不同的图）。
class _RingPainter extends CustomPainter {
  _RingPainter({required this.live});

  final bool live;

  @override
  void paint(Canvas canvas, Size size) {
    final center = size.center(Offset.zero);
    final r = (size.shortestSide / 2) - 12;
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2
      ..strokeCap = StrokeCap.round
      ..color = live
          ? A.petalB.withValues(alpha: 0.42)
          : T.wisteria.withValues(alpha: 0.20);
    const segs = 12;
    for (var i = 0; i < segs; i++) {
      final start = (i / segs) * 2 * 3.1415926535 + 0.10;
      canvas.drawArc(
        Rect.fromCircle(center: center, radius: r),
        start,
        (2 * 3.1415926535 / segs) - 0.20,
        false,
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _RingPainter old) => old.live != live;
}

/// 环形上的读数气泡。
class _Bubble extends StatelessWidget {
  const _Bubble({
    required this.label,
    required this.value,
    required this.accent,
  });

  final String label;
  final String value;
  final Color accent;

  @override
  Widget build(BuildContext context) {
    return MediaQuery.withClampedTextScaling(
      maxScaleFactor: 1.0,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 4),
        decoration: BoxDecoration(
          color: T.bgDeep.withValues(alpha: 0.62),
          borderRadius: BorderRadius.circular(9),
          border: Border.all(color: accent.withValues(alpha: 0.34)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.center,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(label, style: tm(7, color: T.faint, ls: 1.0)),
            const SizedBox(height: 1),
            Text(
              value,
              style: tm(9.5, color: accent, ls: 0.2, weight: FontWeight.w600),
            ),
          ],
        ),
      ),
    );
  }
}

/// 圆形主按钮：57dp，渐变填充 + 双层光晕，运行中变樱花描边。
class _RoundMainButton extends StatelessWidget {
  const _RoundMainButton({
    required this.label,
    required this.busy,
    required this.stop,
    required this.onTap,
  });

  final String label;
  final bool busy;
  final bool stop;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: busy ? null : onTap,
      child: AnimatedOpacity(
        duration: const Duration(milliseconds: 200),
        opacity: busy ? 0.55 : 1,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeOut,
          width: 76,
          height: 76,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            gradient: stop
                ? null
                : const LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: A.btnGrad,
                  ),
            color: stop ? A.petalB.withValues(alpha: 0.12) : null,
            border: Border.all(
              color: stop
                  ? A.petalB.withValues(alpha: 0.75)
                  : A.petalA.withValues(alpha: 0.95),
              width: stop ? 1.6 : 1.4,
            ),
            boxShadow: stop
                ? T.glow(A.petalB, blur: 22, alpha: 0.30)
                : [
                    BoxShadow(
                      color: A.petalB.withValues(alpha: 0.52),
                      blurRadius: 26,
                    ),
                    BoxShadow(
                      color: T.wisteriaDeep.withValues(alpha: 0.34),
                      blurRadius: 40,
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
                      color: stop ? A.petalB : T.ink,
                    ),
                  )
                : Text(
                    label,
                    style: ts(
                      12.5,
                      color: stop ? A.petalA : T.ink,
                      ls: 1.6,
                      weight: FontWeight.w700,
                      height: 1.1,
                    ),
                  ),
          ),
        ),
      ),
    );
  }
}

/// 呼吸 glyph：48dp 圆，运行时描边与光晕脉动。
class _PulseGlyph extends StatefulWidget {
  const _PulseGlyph({required this.running, required this.ok});

  final bool running;
  final bool ok;

  @override
  State<_PulseGlyph> createState() => _PulseGlyphState();
}

class _PulseGlyphState extends State<_PulseGlyph>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 2600),
  );

  @override
  void initState() {
    super.initState();
    if (widget.running) _c.repeat(reverse: true);
  }

  @override
  void didUpdateWidget(covariant _PulseGlyph old) {
    super.didUpdateWidget(old);
    if (widget.running && !_c.isAnimating) {
      _c.repeat(reverse: true);
    } else if (!widget.running && _c.isAnimating) {
      _c.stop();
      _c.value = 0;
    }
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _c,
      builder: (_, _) {
        final pulse = widget.running ? _c.value : 0.0;
        return Container(
          width: 44,
          height: 44,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            gradient: RadialGradient(
              colors: [
                A.petalB.withValues(alpha: widget.running ? 0.32 : 0.14),
                A.petalB.withValues(alpha: 0.02),
              ],
            ),
            border: Border.all(
              color: A.petalB.withValues(
                alpha: widget.running ? 0.58 + pulse * 0.34 : 0.30,
              ),
              width: 1.4,
            ),
            boxShadow: widget.running
                ? [
                    BoxShadow(
                      color: A.petalB.withValues(alpha: 0.30 + pulse * 0.28),
                      blurRadius: 18 + pulse * 12,
                    ),
                  ]
                : null,
          ),
          child: Center(
            child: LineIcon(
              widget.ok ? icoEye : icoGlasses,
              size: 20,
              color: widget.running ? A.petalA : T.faint,
              stroke: 1.4,
            ),
          ),
        );
      },
    );
  }
}

/// 宫格操作块：图标在上、标题在中、提示在下，禁用时整体降透明度。
class _ActionTile extends StatelessWidget {
  const _ActionTile({
    required this.icon,
    required this.label,
    required this.hint,
    required this.onTap,
    required this.enabled,
  });

  final Ico icon;
  final String label;
  final String hint;
  final VoidCallback? onTap;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: enabled ? onTap : null,
      child: AnimatedOpacity(
        duration: const Duration(milliseconds: 240),
        opacity: enabled ? 1 : 0.42,
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 13, horizontal: 10),
          decoration: BoxDecoration(
            color: T.wisteria.withValues(alpha: 0.09),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(
              color: enabled
                  ? T.lineSakura
                  : T.wisteria.withValues(alpha: 0.16),
            ),
            boxShadow:
                enabled ? T.glow(T.wisteriaDeep, blur: 14, alpha: 0.16) : null,
          ),
          child: Column(
            children: [
              LineIcon(
                icon,
                size: 17,
                stroke: 1.5,
                color: enabled ? A.petalA : T.faint,
              ),
              const SizedBox(height: 7),
              Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: ts(11, ls: 0.4, color: enabled ? T.fg : T.dim),
              ),
              const SizedBox(height: 2),
              Text(
                hint,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: tm(7.5, color: T.faint, ls: 0.3),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 参数胶囊：小标签 + 值，横向排布用。
class _ParamChip extends StatelessWidget {
  const _ParamChip({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return MediaQuery.withClampedTextScaling(
      maxScaleFactor: 1.1,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 7),
        decoration: BoxDecoration(
          color: T.wisteria.withValues(alpha: 0.07),
          borderRadius: BorderRadius.circular(999),
          border: Border.all(color: T.wisteria.withValues(alpha: 0.20)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(label, style: tm(8, color: T.faint, ls: 0.8)),
            const SizedBox(width: 6),
            Text(
              value,
              style: tm(10, color: A.petalA, ls: 0.2, weight: FontWeight.w600),
            ),
          ],
        ),
      ),
    );
  }
}
