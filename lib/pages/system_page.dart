import 'package:flutter/material.dart';

import '../engine/engine_client.dart';
import '../theme/app_theme.dart';
import '../widgets/anime.dart';
import '../widgets/icons.dart';
import '../widgets/ui.dart';

/// 系统页 ——「夜桜」v2 重排
///
/// 与 v1 的结构差异（真重排）：
///  v1：辅助能力两行 → 诊断表（13 行全展开）→ 两按钮 → 截图录像列表 → 脚注
///      —— 诊断表 13 行占满一屏，把"截图/录像"这些真操作挤到屏幕外
///  v2：**状态灯网格**（4 个圆灯一眼看全所有子系统是否就绪）
///      → **操作宫格**（截图/录像/目录/授权做成 2×2 方块，图标大字少）
///      → **诊断折叠**（默认收起，点一下展开）→ 底部小字
///      把"看一眼"和"点一下"两件事分开：看在上、做在中、查验收在折叠里。
class SystemPage extends StatefulWidget {
  const SystemPage({super.key, required this.engine});

  final EngineModel engine;

  @override
  State<SystemPage> createState() => _SystemPageState();
}

class _SystemPageState extends State<SystemPage> {
  bool _diagOpen = false;

  EngineModel get engine => widget.engine;

  @override
  Widget build(BuildContext context) {
    final s = engine.status;
    final c = engine.config ?? const EngineConfig();

    return PageShell(
      eyebrow: 'Yozakura · ④',
      title: '系统',
      subtitle: '子系统状态、采集操作与诊断读数',
      pill: StatusPill(
        running: s.running,
        starting: s.starting,
        error: engine.lastError != null,
      ),
      children: [
        // ── ① 状态灯网格：2×2，每个灯是一个子系统的就绪指示
        RiseIn(
          index: 0,
          child: Row(
            children: [
              Expanded(
                child: _LampTile(
                  label: '无障碍',
                  code: 'A11Y',
                  on: s.accessibilityEnabled,
                  onTap: engine.openAccessibilitySettings,
                ),
              ),
              const SizedBox(width: 9),
              Expanded(
                child: _LampTile(
                  label: 'Shizuku',
                  code: 'SHZK',
                  on: s.shizukuReady,
                  onTap: engine.requestShizuku,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 9),
        RiseIn(
          index: 1,
          child: Row(
            children: [
              Expanded(
                child: _LampTile(
                  label: '眼镜',
                  code: 'GLSS',
                  on: s.glasses,
                  onTap: engine.refresh,
                ),
              ),
              const SizedBox(width: 9),
              Expanded(
                child: _LampTile(
                  label: 'IMU',
                  code: 'IMU',
                  on: s.imu.open,
                  onTap: engine.recalibrate,
                ),
              ),
            ],
          ),
        ),

        // ── ② 采集操作宫格：2×2
        const SizedBox(height: 16),
        RiseIn(
          index: 2,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Expanded(
                    child: _OpTile(
                      icon: icoShot,
                      label: '截图',
                      hint: s.running ? '存 PNG' : '需先投屏',
                      enabled: s.running,
                      onTap: () => _doShot(context, engine),
                    ),
                  ),
                  const SizedBox(width: 9),
                  Expanded(
                    child: _OpTile(
                      icon: icoRecord,
                      label: s.shots.recording ? '停止录制' : '录像',
                      hint: s.shots.recording ? '再点结束' : '存 MP4',
                      enabled: s.running,
                      accent: s.shots.recording ? T.red : null,
                      onTap: () => _doRecord(context, engine),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 9),
              Row(
                children: [
                  Expanded(
                    child: _OpTile(
                      icon: icoFolder,
                      label: '打开目录',
                      hint: '截图录像存放',
                      enabled: true,
                      onTap: () => engine.openCaptureFolder(),
                    ),
                  ),
                  const SizedBox(width: 9),
                  Expanded(
                    child: _OpTile(
                      icon: icoShield,
                      label: '授权申请',
                      hint: '通知/相册/存储',
                      enabled: true,
                      onTap: () => engine.ensurePermissions(),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),

        // ── 维护动作：只在需要时出现
        const SizedBox(height: 12),
        Row(
          children: [
            if (s.running) ...[
              Expanded(
                child: SecButton(
                  label: '重连画面',
                  icon: icoExpand,
                  onPressed: engine.reviveStage,
                ),
              ),
              const SizedBox(width: 9),
            ],
            Expanded(
              child: SecButton(
                label: '重新校准',
                icon: icoRecenter,
                onPressed: engine.recalibrate,
              ),
            ),
          ],
        ),

        if (s.mode == 'hosted' && s.running) ...[
          const SizedBox(height: 9),
          SecButton(
            label: '杀掉目标应用',
            icon: icoKill,
            onPressed: () => _doKill(context, engine),
          ),
        ],

        const SizedBox(height: 16),
        const PanelRule(label: 'DIAG'),

        // ── ③ 诊断折叠：默认收起，点标题展开
        RiseIn(
          index: 3,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () => setState(() => _diagOpen = !_diagOpen),
            child: Container(
              padding: const EdgeInsets.fromLTRB(13, 12, 13, 12),
              decoration: BoxDecoration(
                color: T.wisteria.withValues(alpha: 0.06),
                borderRadius: BorderRadius.circular(15),
                border: Border.all(color: T.wisteria.withValues(alpha: 0.20)),
              ),
              child: Row(
                children: [
                  Text(
                    '诊断读数',
                    style: ts(11.5, ls: 0.5, color: T.dim),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      _diagOpen ? '' : '帧 ${s.frames} · 比 ${s.aspect.toStringAsFixed(2)}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: tm(8, color: T.faint, ls: 0.3),
                    ),
                  ),
                  AnimatedRotation(
                    duration: const Duration(milliseconds: 260),
                    turns: _diagOpen ? 0.25 : 0,
                    child: LineIcon(
                      icoChevron,
                      size: 13,
                      stroke: 1.6,
                      color: _diagOpen ? A.petalA : T.faint,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),

        AnimatedCrossFade(
          duration: const Duration(milliseconds: 300),
          crossFadeState: _diagOpen
              ? CrossFadeState.showSecond
              : CrossFadeState.showFirst,
          firstChild: const SizedBox(width: double.infinity, height: 0),
          secondChild: Padding(
            padding: const EdgeInsets.only(top: 10),
            child: DiagCard(
              rows: [
                ('显示器', s.displayName),
                ('显示 id', '${s.displayId}'),
                (
                  '画面宿主',
                  s.stageReady
                      ? '副屏任务'
                      : (s.stageLaunched
                          ? '副屏启动中'
                          : (s.presentation ? 'Presentation' : '—'))
                ),
                (
                  '捕获',
                  s.capture.w > 0
                      ? '期望 ${s.capture.wantW}×${s.capture.wantH} · '
                          '实际 ${s.capture.w}×${s.capture.h}'
                      : '—'
                ),
                (
                  'IMU',
                  s.imu.open ? '${s.imu.frames} 帧 · ${s.imu.sendMode}' : '未打开'
                ),
                ('画面比例', '${s.aspect.toStringAsFixed(2)} : 1'),
                ('帧数', '${s.frames}'),
                (
                  '画面更新',
                  !s.running
                      ? '—'
                      : s.frameStalled
                          ? '${(s.frameIdleMs / 1000).round()} 秒无新帧'
                          : '${(s.frameIdleMs / 1000).toStringAsFixed(1)} 秒前'
                ),
                (
                  '估计零偏',
                  s.pose.tracking
                      ? '${s.pose.biasDps.toStringAsFixed(2)} °/s'
                      : '—'
                ),
                (
                  '静止残差',
                  s.pose.tracking
                      ? '${s.pose.residualDps.toStringAsFixed(2)} °/s'
                      : '—'
                ),
                (
                  '零偏校准',
                  !s.pose.tracking
                      ? '—'
                      : s.pose.firstCal
                          ? '已完成'
                          : '进行中… 保持不动 0.8 秒'
                ),
                ('引擎版本', c.version.isEmpty ? '—' : c.version),
                (
                  '最近产物',
                  s.shots.recording
                      ? '正在录制…'
                      : (s.shots.hasLast ? s.shots.lastPath! : '—')
                ),
                if (s.shots.permissionNote.isNotEmpty)
                  ('权限', s.shots.permissionNote),
              ],
            ),
          ),
        ),

        const FootNote('画面卡死但姿态还在动 → 「杀掉目标应用」重拉 · 详细日志 adb logcat -s GlassEngine'),
      ],
    );
  }

  Future<void> _doShot(BuildContext context, EngineModel engine) async {
    final messenger = ScaffoldMessenger.maybeOf(context);
    // 用 screenshotChecked：它在原生超时后会再刷一次状态，
    // 拿产物路径来判断"其实已经存下来了"，避免"报失败但相册里有图"。
    final out = await engine.screenshotChecked();
    messenger?.showSnackBar(SnackBar(
      content: Text(out.message),
      duration: const Duration(seconds: 3),
    ));
  }

  Future<void> _doRecord(BuildContext context, EngineModel engine) async {
    final messenger = ScaffoldMessenger.maybeOf(context);
    try {
      if (engine.status.shots.recording) {
        final p = await engine.recordStop();
        messenger?.showSnackBar(SnackBar(
          content: Text(p == null ? '录像已停止' : '录像已保存：$p'),
          duration: const Duration(seconds: 3),
        ));
      } else {
        final p = await engine.recordStart();
        messenger?.showSnackBar(SnackBar(
          content: Text(p == null ? '录像启动失败' : '开始录制：$p'),
          duration: const Duration(seconds: 3),
        ));
      }
    } catch (e) {
      messenger?.showSnackBar(SnackBar(content: Text('录像操作失败：$e')));
    }
  }

  Future<void> _doKill(BuildContext context, EngineModel engine) async {
    final messenger = ScaffoldMessenger.maybeOf(context);
    try {
      final pkg = await engine.killHosted();
      messenger?.showSnackBar(SnackBar(
        content: Text(pkg == null ? '已请求重启' : '已重启：$pkg'),
        duration: const Duration(seconds: 3),
      ));
    } catch (e) {
      messenger?.showSnackBar(SnackBar(content: Text('重启失败：$e')));
    }
  }
}

/// 状态灯方块：左上角一个小圆灯（亮=就绪），右侧名称 + 代号。
/// 整块可点，点一下执行该子系统的"去设置/去授权/重检测"动作。
class _LampTile extends StatelessWidget {
  const _LampTile({
    required this.label,
    required this.code,
    required this.on,
    required this.onTap,
  });

  final String label;
  final String code;
  final bool on;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final tone = on ? T.mint : T.faint;
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 280),
        padding: const EdgeInsets.fromLTRB(11, 10, 11, 11),
        decoration: BoxDecoration(
          color: on
              ? T.mint.withValues(alpha: 0.09)
              : T.wisteria.withValues(alpha: 0.05),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: on
                ? T.mint.withValues(alpha: 0.42)
                : T.wisteria.withValues(alpha: 0.16),
            width: on ? 1.3 : 1,
          ),
          boxShadow: on ? T.glow(T.mint, blur: 16, alpha: 0.22) : null,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  width: 6,
                  height: 6,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: tone,
                    boxShadow: on ? T.glow(T.mint, blur: 9, alpha: 0.85) : null,
                  ),
                ),
                const Spacer(),
                Text(code, style: tm(7, color: T.ghost, ls: 0.6)),
              ],
            ),
            const SizedBox(height: 9),
            Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: ts(
                11,
                ls: 0.3,
                color: on ? T.fg : T.dim,
                weight: on ? FontWeight.w600 : FontWeight.w400,
              ),
            ),
            const SizedBox(height: 2),
            Text(
              on ? '就绪' : '未就绪',
              style: tm(7, color: tone, ls: 0.5),
            ),
          ],
        ),
      ),
    );
  }
}

/// 操作方块：图标 + 标题 + 提示，禁用时降透明度且不可点。
class _OpTile extends StatelessWidget {
  const _OpTile({
    required this.icon,
    required this.label,
    required this.hint,
    required this.enabled,
    required this.onTap,
    this.accent,
  });

  final Ico icon;
  final String label;
  final String hint;
  final bool enabled;
  final VoidCallback onTap;
  final Color? accent;

  @override
  Widget build(BuildContext context) {
    final tone = accent ?? A.petalA;
    return GestureDetector(
      onTap: enabled ? onTap : null,
      child: AnimatedOpacity(
        duration: const Duration(milliseconds: 240),
        opacity: enabled ? 1 : 0.40,
        child: Container(
          padding: const EdgeInsets.fromLTRB(11, 12, 11, 12),
          decoration: BoxDecoration(
            gradient: enabled
                ? LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: [
                      tone.withValues(alpha: 0.16),
                      T.wisteria.withValues(alpha: 0.08),
                    ],
                  )
                : null,
            color: enabled ? null : T.wisteria.withValues(alpha: 0.05),
            borderRadius: BorderRadius.circular(14),
            border: Border.all(
              color: enabled
                  ? tone.withValues(alpha: 0.42)
                  : T.wisteria.withValues(alpha: 0.14),
            ),
            boxShadow:
                enabled ? T.glow(tone, blur: 14, alpha: 0.16) : null,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              LineIcon(
                icon,
                size: 18,
                stroke: 1.5,
                color: enabled ? tone : T.faint,
              ),
              const SizedBox(height: 8),
              Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: ts(
                  11,
                  ls: 0.3,
                  color: enabled ? T.fg : T.dim,
                  weight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                hint,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: tm(7, color: T.faint, ls: 0.3),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
