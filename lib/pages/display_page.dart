import 'package:flutter/material.dart';

import '../engine/engine_client.dart';
import '../theme/app_theme.dart';
import '../widgets/anime.dart';
import '../widgets/ui.dart';
import 'app_picker.dart';

/// 画面页 ——「夜桜」v2 重排
///
/// 与 v1 的结构差异：
///  v1：分组标题 + 分段控件三段并列（投屏方式 / 投屏模式 / 参数）+ 大滑杆
///  v2：**编号步骤卡**——① 选方式、② 选模式、③ 调参数，每步一张可点卡片，
///      选项以「胶囊按钮组」横排贴底；参数区改成**两列紧凑滑杆 + 右侧读数**。
///      窄面板里分段控件（三等分）会把每个选项压到 60px 以下，字必然溢出，
///      所以换成可换行（Wrap）的胶囊组，宽度不够就自动折行。
class DisplayPage extends StatelessWidget {
  const DisplayPage({super.key, required this.engine});

  final EngineModel engine;

  static const List<_Color> _colors = [
    _Color('红', 11, T.red),
    _Color('青', 12, T.cyan),
    _Color('黄', 13, T.amber),
  ];

  static const List<String> _resLabels = ['1920', '1600', '1280'];

  static String _modeDesc(String v) => switch (v) {
        'track' => '画面被拖后一点，再平滑滑回眼前；歪头时画面自动摆正',
        'extend' => '不做 3DoF：画面固定贴在眼前，等同普通外接屏',
        _ => '画面钉在空间里：转头时它留在原处，会滑出视野',
      };

  @override
  Widget build(BuildContext context) {
    final s = engine.status;
    final c = engine.config ?? const EngineConfig();
    final canEdit = !s.running && !s.starting;
    final viewIndex = switch (c.viewMode) {
      'track' => 1,
      'extend' => 2,
      _ => 0,
    };

    return PageShell(
      eyebrow: 'Yozakura · ②',
      title: '画面',
      subtitle: _modeDesc(c.viewMode),
      pill: StatusPill(
        running: s.running,
        starting: s.starting,
        error: engine.lastError != null,
      ),
      children: [
        // ── 步骤 ①：投屏方式
        _StepCard(
          step: '01',
          title: '投屏方式',
          note: canEdit ? null : '运行中不可切换，先停止投屏',
          enabled: canEdit,
          body: Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              _ChoicePill(
                label: '镜像整屏',
                selected: !c.hosted,
                onTap: canEdit ? () => engine.setMode('mirror') : null,
              ),
              _ChoicePill(
                label: '扩展屏',
                selected: c.hosted,
                onTap: canEdit ? () => engine.setMode('hosted') : null,
              ),
            ],
          ),
        ),

        if (c.hosted) ...[
          const SizedBox(height: 10),
          GroupCard(
            children: [
              HairRow(
                label: '目标应用',
                sub: '把任意应用启动到眼镜屏',
                value: c.label ?? '未选择',
                onTap: canEdit ? () => showAppPicker(context, engine) : null,
              ),
            ],
          ),
          const Hint('扩展屏由 Shizuku 建受信虚拟屏，等同真实外接显示器，需先授权'),
        ],

        const SizedBox(height: 12),

        // ── 步骤 ②：投屏模式
        _StepCard(
          step: '02',
          title: '投屏模式',
          note: s.running ? '切换即时生效' : '未开始投屏：设置已保存',
          body: Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (var i = 0; i < 3; i++)
                _ChoicePill(
                  label: const ['悬停', '追踪', '扩展'][i],
                  selected: viewIndex == i,
                  onTap: () => engine.setPose(
                    viewMode: const ['hover', 'track', 'extend'][i],
                  ),
                ),
            ],
          ),
        ),

        const SizedBox(height: 12),

        // ── 步骤 ③：画面参数
        _StepCard(
          step: '03',
          title: '画面参数',
          body: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _CompactSlider(
                label: '尺寸',
                readout: '${(0.3 + c.size / 100).toStringAsFixed(2)}×',
                value: c.size.toDouble(),
                min: 0,
                max: 170,
                divisions: 34,
                onChanged: (v) => engine.setParams(size: v.round()),
              ),
              const SizedBox(height: 6),
              _CompactSlider(
                label: '虚拟距离',
                readout: '${(1 + c.distance / 10).toStringAsFixed(1)} m',
                value: c.distance.toDouble(),
                min: 0,
                max: 100,
                divisions: 100,
                onChanged: (v) => engine.setParams(distance: v.round()),
              ),
              const SizedBox(height: 6),
              _CompactSlider(
                label: '垂直视场角',
                readout: '${15 + c.fov}°',
                value: c.fov.toDouble(),
                min: 0,
                max: 30,
                divisions: 30,
                onChanged: (v) => engine.setParams(fov: v.round()),
              ),
              const SizedBox(height: 12),
              Text('捕获清晰度', style: ts(11.5, ls: 0.3, color: T.dim)),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (var i = 0; i < _resLabels.length; i++)
                    _ChoicePill(
                      label: _resLabels[i],
                      selected: c.resolution.clamp(0, 2) == i,
                      onTap: () => engine.setResolution(i),
                    ),
                ],
              ),
            ],
          ),
        ),

        const Hint('改完即时生效并自动保存 · Air 1s 视场角实测约 23°'),

        if (s.running) ...[
          const SizedBox(height: 12),
          // ── 步骤 ④：亮度与色彩（只有运行中才有）
          _StepCard(
            step: '04',
            title: '亮度与色彩',
            note: '仅开始投屏后可用',
            body: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _CompactSlider(
                  label: '亮度',
                  readout: '${c.panelLevel} / 10',
                  value: c.panelLevel.toDouble(),
                  min: 1,
                  max: 10,
                  divisions: 9,
                  onChanged: (v) => engine.setPanelLevel(v.round()),
                ),
                const SizedBox(height: 10),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (final o in _colors)
                      _ChoicePill(
                        label: o.label,
                        selected: c.color == o.level,
                        swatch: o.swatch,
                        onTap: () => engine.setPanelLevel(
                          c.color == o.level ? c.panelLevel : o.level,
                        ),
                      ),
                  ],
                ),
                const SizedBox(height: 8),
                Text(
                  '色彩接管整屏色调，再点一次回到亮度档',
                  style: tm(7.5, color: T.faint, ls: 0.3, height: 1.6),
                ),
              ],
            ),
          ),
        ],
      ],
    );
  }
}

/// 步骤卡：左上角一个大号编号 + 标题，下方是内容。
///
/// 为什么用编号：窄面板里没法用"分组标题 + 缩进"表达层级（没有横向空间），
/// 用编号把顺序写死在视觉上，用户一眼知道先选什么后调什么。
class _StepCard extends StatelessWidget {
  const _StepCard({
    required this.step,
    required this.title,
    required this.body,
    this.note,
    this.enabled = true,
  });

  final String step;
  final String title;
  final Widget body;
  final String? note;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    return AnimatedOpacity(
      duration: const Duration(milliseconds: 240),
      opacity: enabled ? 1 : 0.72,
      child: CelCard(
        padding: const EdgeInsets.fromLTRB(14, 13, 14, 14),
        grad: const [A.petalB, T.wisteria, T.sky],
        glow: true,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 6,
                    vertical: 2,
                  ),
                  decoration: BoxDecoration(
                    color: A.petalB.withValues(alpha: 0.18),
                    borderRadius: BorderRadius.circular(6),
                    border: Border.all(
                      color: A.petalB.withValues(alpha: 0.45),
                    ),
                  ),
                  child: Text(
                    step,
                    style: tm(
                      9,
                      color: A.petalA,
                      ls: 0.8,
                      weight: FontWeight.w700,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    title,
                    style: ts(12.5, ls: 0.4, weight: FontWeight.w600),
                  ),
                ),
              ],
            ),
            if (note != null) ...[
              const SizedBox(height: 5),
              Text(
                note!,
                style: tm(7.5, color: T.faint, ls: 0.3, height: 1.5),
              ),
            ],
            const SizedBox(height: 11),
            body,
          ],
        ),
      ),
    );
  }
}

/// 选项胶囊：选中态樱花实底 + 描边 + 光晕；可选前置色点。
class _ChoicePill extends StatelessWidget {
  const _ChoicePill({
    required this.label,
    required this.selected,
    required this.onTap,
    this.swatch,
  });

  final String label;
  final bool selected;
  final VoidCallback? onTap;
  final Color? swatch;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 240),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          gradient: selected
              ? const LinearGradient(
                  colors: [Color(0x59FF9CCB), Color(0x3DC39BFF)],
                )
              : null,
          color: selected ? null : T.wisteria.withValues(alpha: 0.07),
          borderRadius: BorderRadius.circular(999),
          border: Border.all(
            color: selected
                ? A.petalB.withValues(alpha: 0.72)
                : T.wisteria.withValues(alpha: 0.18),
            width: selected ? 1.4 : 1,
          ),
          boxShadow:
              selected ? T.glow(A.petalB, blur: 14, alpha: 0.30) : null,
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (swatch != null) ...[
              Container(
                width: 7,
                height: 7,
                decoration: BoxDecoration(
                  color: swatch,
                  shape: BoxShape.circle,
                  boxShadow:
                      selected ? T.glow(swatch!, blur: 9, alpha: 0.8) : null,
                ),
              ),
              const SizedBox(width: 6),
            ],
            Text(
              label,
              maxLines: 1,
              style: tm(
                10,
                color: selected ? A.petalA : T.dim,
                ls: 0.5,
                weight: selected ? FontWeight.w700 : FontWeight.w400,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 紧凑滑杆：标签和读数同一行（两端贴边），滑杆在下面占满宽。
/// 比 SliderBlock 省一半高度，窄面板里一屏能塞下三个。
class _CompactSlider extends StatelessWidget {
  const _CompactSlider({
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
  final int? divisions;
  final ValueChanged<double> onChanged;

  @override
  Widget build(BuildContext context) {
    return MediaQuery.withClampedTextScaling(
      maxScaleFactor: 1.1,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: ts(11.5, ls: 0.3, color: T.dim),
                ),
              ),
              const SizedBox(width: 8),
              Text(
                readout,
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
            value: value,
            min: min,
            max: max,
            divisions: divisions,
            onChanged: onChanged,
          ),
        ],
      ),
    );
  }
}

class _Color {
  const _Color(this.label, this.level, this.swatch);

  final String label;
  final int level;
  final Color swatch;
}
