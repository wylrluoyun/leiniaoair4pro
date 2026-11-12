import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../engine/engine_client.dart';
import '../theme/app_theme.dart';
import '../widgets/icons.dart';
import '../widgets/ui.dart';

/// 手机端触控板（替代原生的 PadActivity）。
///
/// 语义与原生一致：手指拖动 → 光标按位移移动；轻点 → 在当前光标位置点击；
/// 按住 500ms → 长按；双指滑动 → 四向滚动。注入通道由引擎决定
/// （Shizuku 优先，无 Shizuku 时走无障碍 dispatchGesture）。
///
/// 视觉上是设计稿的"纯黑全屏"版式：顶部一排圆形图标、中间虚线触控面、
/// 底部亮度与色彩。投屏时手机当遥控器，任何亮色块都会晃眼。
class PadPage extends StatefulWidget {
  const PadPage({super.key, required this.engine});

  final EngineModel engine;

  @override
  State<PadPage> createState() => _PadPageState();
}

class _PadPageState extends State<PadPage> {
  static const double _gain = 1.6;
  static const int _tapSlopDp = 10;
  static const int _scrollStepDp = 46;
  static const Duration _longPress = Duration(milliseconds: 500);
  static const Duration _scrollInterval = Duration(milliseconds: 120);

  static const List<(String, int, Color)> _colors = [
    ('红', 11, T.red),
    ('青', 12, T.cyan),
    ('黄', 13, T.amber),
  ];

  final Map<int, Offset> _pointers = {};
  final List<(int, Offset)> _ripples = [];
  int _rippleSeq = 0;

  Offset _lastCentroid = Offset.zero;
  Offset _downAt = Offset.zero;
  bool _moved = false;
  bool _scrollMode = false;
  int _scrollAxis = 0;
  double _scrollAcc = 0;
  DateTime _lastScrollAt = DateTime.fromMillisecondsSinceEpoch(0);
  Timer? _longPressTimer;
  bool _longPressFired = false;

  double _u = 0.5;
  double _v = 0.5;
  bool _blackout = false;

  EngineModel get engine => widget.engine;

  @override
  void initState() {
    super.initState();
    engine.addListener(_repaint);
    engine.setCursor(u: _u, v: _v, visible: true);
  }

  @override
  void dispose() {
    engine.removeListener(_repaint);
    _longPressTimer?.cancel();
    engine.setCursor(visible: false);
    // 熄屏时进过沉浸模式，离开页面必须还原，否则状态栏一直不回来
    if (_blackout) {
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    }
    super.dispose();
  }

  void _repaint() {
    if (mounted) setState(() {});
  }

  /// 熄屏：眼镜里连光标一起隐藏，手机整屏纯黑（连状态栏都不留），轻触恢复。
  void _enterBlackout() {
    if (_blackout) return;
    setState(() => _blackout = true);
    engine.setCursor(visible: false);
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
  }

  void _exitBlackout() {
    if (!_blackout) return;
    setState(() => _blackout = false);
    engine.setCursor(visible: true);
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
  }

  // ------------------------------------------------------------ 手势

  void _ripple(Offset at) {
    final id = _rippleSeq++;
    setState(() => _ripples.add((id, at)));
  }

  void _onDown(PointerDownEvent e) {
    _ripple(e.localPosition);
    _pointers[e.pointer] = e.localPosition;
    if (_pointers.length == 1) {
      _downAt = e.localPosition;
      _moved = false;
      _scrollMode = false;
      _scrollAxis = 0;
      _scrollAcc = 0;
      _lastCentroid = e.localPosition;
      _longPressFired = false;
      _longPressTimer?.cancel();
      _longPressTimer = Timer(_longPress, () {
        if (!_moved && _pointers.length == 1) {
          _longPressFired = true;
          HapticFeedback.mediumImpact();
          engine.tap(longPress: true);
        }
      });
    } else if (_pointers.length == 2) {
      _longPressTimer?.cancel();
      _scrollMode = true;
      _scrollAxis = 0;
      _scrollAcc = 0;
      _moved = true;
      _lastCentroid = _centroid();
    }
  }

  Offset _centroid() {
    if (_pointers.isEmpty) return Offset.zero;
    var sum = Offset.zero;
    for (final p in _pointers.values) {
      sum += p;
    }
    return sum / _pointers.length.toDouble();
  }

  void _onMove(PointerMoveEvent e) {
    if (!_pointers.containsKey(e.pointer)) return;
    _pointers[e.pointer] = e.localPosition;

    if (_scrollMode && _pointers.length >= 2) {
      final c = _centroid();
      final d = c - _lastCentroid;
      _lastCentroid = c;
      if (_scrollAxis == 0) {
        if (d.dx.abs() + d.dy.abs() < 6) return;
        _scrollAxis = d.dx.abs() > d.dy.abs() ? 1 : 2;
      }
      _scrollAcc += _scrollAxis == 1 ? d.dx : d.dy;
      const step = _scrollStepDp * 1.0;
      while (_scrollAcc.abs() >= step) {
        final dir = _scrollAcc > 0 ? 1 : -1;
        _scrollAcc -= dir * step;
        _fireScroll(_scrollAxis, dir);
      }
      return;
    }

    if (_pointers.length != 1) return;

    final last = _lastCentroid;
    _lastCentroid = e.localPosition;
    final delta = e.localPosition - last;
    final box = context.size;
    if (box == null || box.width <= 0 || box.height <= 0) return;

    setState(() {
      _u = (_u + delta.dx * _gain / box.width).clamp(0.0, 1.0);
      _v = (_v + delta.dy * _gain / box.height).clamp(0.0, 1.0);
    });
    engine.setCursor(u: _u, v: _v);

    if ((e.localPosition - _downAt).distance > _tapSlopDp) {
      _moved = true;
      _longPressTimer?.cancel();
    }
  }

  void _onUp(PointerUpEvent e) {
    _pointers.remove(e.pointer);
    if (_pointers.isEmpty) {
      _longPressTimer?.cancel();
      if (!_moved && !_longPressFired) {
        HapticFeedback.selectionClick();
        engine.tap();
      }
      _scrollMode = false;
      _moved = false;
    } else if (_pointers.length == 1) {
      _lastCentroid = _pointers.values.first;
      _scrollMode = false;
    }
  }

  void _onCancel(PointerCancelEvent e) {
    _pointers.remove(e.pointer);
    _longPressTimer?.cancel();
    if (_pointers.isEmpty) {
      _scrollMode = false;
      _moved = false;
    }
  }

  void _fireScroll(int axis, int dir) {
    final now = DateTime.now();
    if (now.difference(_lastScrollAt) < _scrollInterval) return;
    _lastScrollAt = now;
    HapticFeedback.selectionClick();
    engine.scroll(axis: axis, dir: dir);
  }

  // ------------------------------------------------------------ 视图

  @override
  Widget build(BuildContext context) {
    final s = engine.status;
    final c = engine.config;

    return Scaffold(
      backgroundColor: T.bgDeep,
      body: Stack(
        children: [
          Column(
            children: [
              _PadHeader(engine: engine, onBlackout: _enterBlackout),
              if (!s.canInjectInput)
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                  child: Row(
                    children: [
                      LineIcon(icoInfo, size: 12, color: T.faint),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text(
                          '未授权注入 · 当前仅显示画面',
                          style: ts(10, color: T.faint, ls: 0.3),
                        ),
                      ),
                    ],
                  ),
                ),
              Expanded(child: _padArea()),
              if (s.running && c != null) _brightnessBar(c),
              const SizedBox(height: 6),
            ],
          ),
          // 熄屏遮罩：纯黑，轻触任意位置恢复
          Positioned.fill(
            child: IgnorePointer(
              ignoring: !_blackout,
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: _exitBlackout,
                child: AnimatedOpacity(
                  opacity: _blackout ? 1 : 0,
                  duration: const Duration(milliseconds: 420),
                  curve: Curves.easeOut,
                  child: ColoredBox(
                    // 熄屏遮罩必须真·全黑，不能带任何紫调，
                    // 否则用户平躺在暗房里仍能感到屏幕发光
                    color: Colors.black,
                    child: Center(
                      child: Text(
                        '轻触任意位置恢复',
                        style: tm(
                          9,
                          color: A.petalB.withValues(alpha: 0.35),
                          ls: 2.3,
                        ),
                      ),
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

  Widget _padArea() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
      child: LayoutBuilder(
        builder: (context, box) {
          final w = box.maxWidth;
          final h = box.maxHeight;
          return Listener(
            behavior: HitTestBehavior.opaque,
            onPointerDown: _onDown,
            onPointerMove: _onMove,
            onPointerUp: _onUp,
            onPointerCancel: _onCancel,
            child: Stack(
              children: [
                Positioned.fill(
                  child: CustomPaint(painter: _DashedBoxPainter()),
                ),
                // 光标位置：极淡的一点，只用来确认手指相对位移没跑偏
                AnimatedPositioned(
                  duration: const Duration(milliseconds: 90),
                  curve: Curves.easeOut,
                  left: (_u * w - 5).clamp(4.0, (w - 14).clamp(4.0, w)),
                  top: (_v * h - 5).clamp(4.0, (h - 14).clamp(4.0, h)),
                  child: Container(
                    width: 10,
                    height: 10,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: A.petalA.withValues(alpha: 0.75),
                      boxShadow: [
                        BoxShadow(
                          color: A.petalB.withValues(alpha: 0.75),
                          blurRadius: 12,
                        ),
                      ],
                    ),
                  ),
                ),
                for (final r in _ripples)
                  Positioned(
                    left: r.$2.dx - 11,
                    top: r.$2.dy - 11,
                    child: _Ripple(
                      key: ValueKey(r.$1),
                      onDone: () {
                        if (!mounted) return;
                        setState(
                            () => _ripples.removeWhere((x) => x.$1 == r.$1));
                      },
                    ),
                  ),
                Positioned(
                  left: 0,
                  right: 0,
                  bottom: 22,
                  child: Text(
                    '拖动移动光标 · 轻点点击\n长按 500ms 长按 · 双指滚动',
                    textAlign: TextAlign.center,
                    style: tm(
                      8,
                      color: T.wisteria.withValues(alpha: 0.45),
                      ls: 1.28,
                      height: 2,
                    ),
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  /// 亮度条：面板档位 1–10 + 红/青/黄。面板命令走会话 HID，仅运行时可用。
  Widget _brightnessBar(EngineConfig c) {
    return Padding(
      padding: EdgeInsets.fromLTRB(20, 10, 20, 14 + MediaQuery.paddingOf(context).bottom),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: [
              Expanded(
                child: Text(
                  '亮度设置'.toUpperCase(),
                  style: tm(9, ls: 1.8),
                ),
              ),
              Text('${c.panelLevel} / 10', style: tm(11, color: T.fg)),
            ],
          ),
          const SizedBox(height: 2),
          HairSlider(
            value: c.panelLevel.toDouble(),
            min: 1,
            max: 10,
            divisions: 9,
            onChanged: (v) => engine.setPanelLevel(v.round()),
          ),
          const SizedBox(height: 12),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              for (final o in _colors) ...[
                ColorChip(
                  label: o.$1,
                  swatch: o.$3,
                  selected: c.color == o.$2,
                  padding: const EdgeInsets.symmetric(horizontal: 15, vertical: 9),
                  onTap: () => engine.setPanelLevel(
                    c.color == o.$2 ? c.panelLevel : o.$2,
                  ),
                ),
                if (o != _colors.last) const SizedBox(width: 8),
              ],
            ],
          ),
        ],
      ),
    );
  }
}

/// 顶部：返回 → 中间状态字 → 复位 / 返回键 / 熄屏 / 停止。
class _PadHeader extends StatelessWidget {
  const _PadHeader({required this.engine, required this.onBlackout});

  final EngineModel engine;
  final VoidCallback onBlackout;

  @override
  Widget build(BuildContext context) {
    final s = engine.status;
    final c = engine.config;
    final res = switch (c?.resolution ?? 0) {
      0 => '1920',
      1 => '1600',
      _ => '1280',
    };
    final status = s.running
        ? '${c?.hosted == true ? '扩展屏' : '镜像'} · $res×1080'
        : '会话未运行';

    return SafeArea(
      bottom: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
        child: Row(
          children: [
            _PadIcon(
              icon: icoBack,
              onTap: () => Navigator.of(context).pop(),
              tooltip: '返回',
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                status.toUpperCase(),
                textAlign: TextAlign.center,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: tm(8.5, ls: 1.2),
              ),
            ),
            const SizedBox(width: 8),
            _PadIcon(
              icon: icoExpand,
              onTap: engine.recenter,
              tooltip: '画面复位',
            ),
            const SizedBox(width: 8),
            _PadIcon(
              icon: icoReturn,
              onTap: () => engine.key(4),
              tooltip: '返回键',
            ),
            const SizedBox(width: 8),
            _PadIcon(
              icon: icoMoon,
              onTap: onBlackout,
              tooltip: '熄屏',
            ),
            const SizedBox(width: 8),
            _PadIcon(
              icon: icoStop,
              onTap: () {
                engine.stop();
                Navigator.of(context).pop();
              },
              tooltip: '停止',
            ),
          ],
        ),
      ),
    );
  }
}

class _PadIcon extends StatelessWidget {
  const _PadIcon({
    required this.icon,
    required this.onTap,
    required this.tooltip,
  });

  final Ico icon;
  final VoidCallback onTap;
  final String tooltip;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      waitDuration: const Duration(milliseconds: 600),
      child: GestureDetector(
        onTap: onTap,
        behavior: HitTestBehavior.opaque,
        child: SizedBox(
          width: 40,
          height: 40,
          child: Center(
            child: Container(
              width: 32,
              height: 32,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                border: Border.all(color: T.hair(0.13)),
              ),
              child: Center(
                child: LineIcon(icon, size: 15, color: T.dim, stroke: 1.5),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 触控面的虚线描边（1px、6-5 间隔、圆角 22）。
class _DashedBoxPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final rrect = RRect.fromRectAndRadius(
      Rect.fromLTWH(0.5, 0.5, size.width - 1, size.height - 1),
      const Radius.circular(22),
    );
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1
      ..color = T.wisteria.withValues(alpha: 0.22);
    final path = Path()..addRRect(rrect);
    for (final metric in path.computeMetrics()) {
      var d = 0.0;
      while (d < metric.length) {
        final next = math.min(d + 6, metric.length);
        canvas.drawPath(metric.extractPath(d, next), paint);
        d = next + 5;
      }
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

/// 按下时的水波：22px 圆环放大到 2.6 倍并淡出。
class _Ripple extends StatelessWidget {
  const _Ripple({super.key, required this.onDone});

  final VoidCallback onDone;

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: TweenAnimationBuilder<double>(
        tween: Tween(begin: 0, end: 1),
        duration: const Duration(milliseconds: 550),
        curve: Curves.easeOut,
        onEnd: onDone,
        builder: (context, t, _) => Opacity(
          opacity: (1 - t).clamp(0.0, 1.0),
          child: Transform.scale(
            scale: 0.3 + t * 2.3,
            child: Container(
              width: 22,
              height: 22,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                border: Border.all(
                  color: A.petalB.withValues(alpha: 0.7),
                  width: 1 + t,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
