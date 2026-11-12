import 'package:flutter/material.dart';

import '../engine/engine_client.dart';
import '../theme/app_theme.dart';
import '../widgets/anime.dart';
import '../widgets/icons.dart';
import '../widgets/ui.dart';

/// 姿态页 ——「夜桜」v2 重排
///
/// 与 v1 的结构差异：
///  v1：跟随速度滑杆 → 静止冻结开关 → 四个取反开关竖排列表
///  v2：**顶部大开关卡**（冻结状态做成一个能整块点击的开关，不是行内小滑块）
///      → 中间是**2×2 轴向矩阵**（每条轴向一张方块，点一下翻转，图标直接
///      画出该轴的箭头方向）→ 底部跟随速度做成横向滑杆。
///      取反列表改成按轴分组不是因为好看，是因为这四个开关本质是一个
///      坐标系矩阵，竖着一列排会让人分不清哪两个属于同一个轴。
class PosePage extends StatelessWidget {
  const PosePage({super.key, required this.engine});

  final EngineModel engine;

  @override
  Widget build(BuildContext context) {
    final s = engine.status;
    final c = engine.config ?? const EngineConfig();
    final tracking = c.viewMode == 'track';

    return PageShell(
      eyebrow: 'Yozakura · ③',
      title: '姿态',
      subtitle: tracking
          ? '越小追得越紧（更像贴脸），越大越有“追上来”的过程'
          : '抑制静止时的画面漂移，让虚拟屏稳稳停在空间里',
      pill: StatusPill(
        running: s.running,
        starting: s.starting,
        error: engine.lastError != null,
      ),
      children: [
        // ── 大开关卡：静止冻结
        RiseIn(
          index: 0,
          child: _BigToggle(
            icon: icoPose,
            title: '静止时冻结',
            sub: tracking ? '滑动结束后自然停在正前方' : '抑制静止时的画面漂移',
            value: c.freeze,
            onChanged: (v) => engine.setPose(freeze: v),
          ),
        ),

        // ── 跟随速度（只在追踪模式下有意义，但保留也让用户知道有这个参数）
        if (tracking) ...[
          const SizedBox(height: 12),
          RiseIn(
            index: 1,
            child: CelCard(
              padding: const EdgeInsets.fromLTRB(14, 12, 14, 8),
              grad: const [A.petalB, T.wisteria],
              glow: false,
              fill: T.wisteria.withValues(alpha: 0.06),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          '跟随速度',
                          style: ts(11.5, ls: 0.3, color: T.dim),
                        ),
                      ),
                      Text(
                        '${c.followTau.toStringAsFixed(2)} s',
                        style: tm(
                          10.5,
                          color: A.petalA,
                          ls: 0.2,
                          weight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 2),
                  HairSlider(
                    value: c.followTau,
                    min: 0.15,
                    max: 1.5,
                    divisions: 27,
                    onChanged: (v) =>
                        engine.setPose(followTau: (v * 100).round() / 100),
                  ),
                ],
              ),
            ),
          ),
          const Hint('越小追得越紧（更像贴脸），越大越有“追上来”的过程'),
        ],

        const SizedBox(height: 14),
        const PanelRule(label: 'AXIS'),

        // ── 轴向矩阵：2×2
        RiseIn(
          index: 2,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Expanded(
                    child: _AxisTile(
                      label: '前后',
                      code: 'fwd',
                      on: c.invertForward,
                      onTap: () =>
                          engine.setPose(invertForward: !c.invertForward),
                      dirIcon: icoChevron,
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: _AxisTile(
                      label: '左右',
                      code: 'yaw',
                      on: c.invertYaw,
                      onTap: () => engine.setPose(invertYaw: !c.invertYaw),
                      dirIcon: icoChevron,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              Row(
                children: [
                  Expanded(
                    child: _AxisTile(
                      label: '上下',
                      code: 'pitch',
                      on: c.invertPitch,
                      onTap: () => engine.setPose(invertPitch: !c.invertPitch),
                      dirIcon: icoChevron,
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: _AxisTile(
                      label: '倾斜',
                      code: 'roll',
                      on: c.invertRoll,
                      onTap: () => engine.setPose(invertRoll: !c.invertRoll),
                      dirIcon: icoChevron,
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),

        const Hint('算法已按 Air 1s 实测预置取反；换机型或固件方向不对时逐轴再反一次，别一次全开'),

        const SizedBox(height: 14),
        const Stardust(),
      ],
    );
  }
}

/// 大开关卡：整块可点，右侧一个放大版 HairSwitch。
class _BigToggle extends StatelessWidget {
  const _BigToggle({
    required this.icon,
    required this.title,
    required this.sub,
    required this.value,
    required this.onChanged,
  });

  final Ico icon;
  final String title;
  final String sub;
  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => onChanged(!value),
      child: CelCard(
        padding: const EdgeInsets.fromLTRB(14, 14, 14, 14),
        grad: value
            ? const [A.petalB, T.wisteria, T.mint]
            : const [T.wisteria, T.sky],
        child: Row(
          children: [
            Container(
              width: 38,
              height: 38,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: value
                    ? T.mint.withValues(alpha: 0.16)
                    : T.wisteria.withValues(alpha: 0.10),
                border: Border.all(
                  color: value
                      ? T.mint.withValues(alpha: 0.55)
                      : T.wisteria.withValues(alpha: 0.28),
                  width: 1.2,
                ),
                boxShadow: value ? T.glow(T.mint, blur: 16, alpha: 0.35) : null,
              ),
              child: Center(
                child: LineIcon(
                  icon,
                  size: 18,
                  stroke: 1.4,
                  color: value ? T.mint : T.faint,
                ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: ts(13, ls: 0.4, weight: FontWeight.w600),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    sub,
                    style: ts(9, color: T.faint, height: 1.45, ls: 0.2),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            HairSwitch(value: value),
          ],
        ),
      ),
    );
  }
}

/// 轴向方块：正中画该轴的箭头，右上角一个"已取反"小标记。
class _AxisTile extends StatelessWidget {
  const _AxisTile({
    required this.label,
    required this.code,
    required this.on,
    required this.onTap,
    required this.dirIcon,
  });

  final String label;
  final String code;
  final bool on;
  final VoidCallback onTap;
  final Ico dirIcon;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 260),
        curve: Curves.easeOut,
        padding: const EdgeInsets.fromLTRB(11, 10, 11, 11),
        decoration: BoxDecoration(
          gradient: on
              ? const LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [Color(0x4DFF9CCB), Color(0x33C39BFF)],
                )
              : null,
          color: on ? null : T.wisteria.withValues(alpha: 0.06),
          borderRadius: BorderRadius.circular(15),
          border: Border.all(
            color: on
                ? A.petalB.withValues(alpha: 0.70)
                : T.wisteria.withValues(alpha: 0.18),
            width: on ? 1.4 : 1,
          ),
          boxShadow: on
              ? T.glow(A.petalB, blur: 18, alpha: 0.26)
              : null,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: ts(
                      12,
                      ls: 0.4,
                      color: on ? T.fg : T.dim,
                      weight: on ? FontWeight.w600 : FontWeight.w400,
                    ),
                  ),
                ),
                // 右上角翻转标记：一个绕过 180° 的半圆箭头
                AnimatedRotation(
                  duration: const Duration(milliseconds: 300),
                  turns: on ? 0.5 : 0,
                  child: LineIcon(
                    icoChevron,
                    size: 13,
                    stroke: 1.6,
                    color: on ? A.petalA : T.faint,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 7),
            // 轴向指示：一条带箭头的短横线，取反后字变樱花色
            Row(
              children: [
                Container(
                  width: 3,
                  height: 3,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: on ? A.petalA : T.faint,
                  ),
                ),
                const SizedBox(width: 5),
                Text(
                  on ? '已取反' : '正常',
                  style: tm(
                    8,
                    color: on ? A.petalA : T.faint,
                    ls: 0.6,
                    weight: on ? FontWeight.w600 : FontWeight.w400,
                  ),
                ),
                const Spacer(),
                Text(code, style: tm(7.5, color: T.ghost, ls: 0.4)),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
