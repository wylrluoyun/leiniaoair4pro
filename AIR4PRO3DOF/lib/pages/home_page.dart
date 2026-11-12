import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../engine/engine_client.dart';
import '../theme/app_theme.dart';
import '../widgets/anime.dart';
import '../widgets/hud.dart';
import 'app_picker.dart';
import 'pad_page.dart';

/// ---------------------------------------------------------------------------
/// 「HOLO」主界面 — 第三版，彻底换了几何语言
///
/// 三次尝试的关键差别（这次是真正的颠覆）：
///
///  v1 极简黑白 → 换成霓虹配色，布局不变            ← 只换皮
///  v2 cover 铺满 + 卡片堆叠 + 胶囊 Tab              ← 布局变了，仍是卡片语言
///  v3（本版）**整幅插画完整呈现 + 无填充线框覆盖层**  ← 几何语言整个换掉
///
/// 本版三条硬规则：
///   ① 背景图**零裁切**：按宽度撑满（390 → 高 551），整幅画 100% 可见。
///      界面元素浮在画上，不是把画当背景盖住。
///   ② **没有实心卡片**：所有容器是无填充的 1px 渐变线框 + 四角加长线。
///      画面从线框中间透出来，避免大面积色块把插画遮死。
///   ③ **没有圆角矩形 Tab**：导航是右侧一个扇形刻度盘，四个扇区沿弧排布。
///      和线框、环形仪表同属"仪器"几何，不再出现"列表"语言的重复。
///
/// 布局骨架：
///   整幅画（551px）  ←  标题墨晕压在上面
///   ────────────────
///   磁带读数条（无底无框）
///   线框内容区（随章节切换，全是线框 + 环形仪表 + 刻度尺）
///   右下斜切主按钮 + 右侧扇形导航
/// ---------------------------------------------------------------------------
class HomePage extends StatefulWidget {
  const HomePage({super.key, required this.engine});

  final EngineModel engine;

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  static const _chapters = ['概览', '画面', '姿态', '系统'];

  /// 原图 1127×1593 的宽高比
  static const _artRatio = 1593.0 / 1127.0;

  int _chapter = 0;
  bool _padOpening = false;

  EngineModel get engine => widget.engine;

  @override
  void initState() {
    super.initState();
    engine.addListener(_onChanged);
    WidgetsBinding.instance.addPostFrameCallback((_) => engine.init());
  }

  @override
  void dispose() {
    engine.removeListener(_onChanged);
    super.dispose();
  }

  void _onChanged() {
    if (!mounted) return;
    final toast = engine.pendingToast;
    if (toast != null && toast.isNotEmpty) {
      engine.consumeToast();
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text(toast)));
    }
    if (engine.padRequested && !_padOpening) {
      engine.consumePadRequest();
      _openPad();
    }
    setState(() {});
  }

  Future<void> _openPad() async {
    _padOpening = true;
    await Navigator.of(context).push(
      PageRouteBuilder<void>(
        transitionDuration: const Duration(milliseconds: 320),
        reverseTransitionDuration: const Duration(milliseconds: 260),
        pageBuilder: (_, _, _) => PadPage(engine: engine),
        transitionsBuilder: (_, animation, _, child) => FadeTransition(
          opacity: CurvedAnimation(
            parent: animation,
            curve: const Cubic(0.2, 0.8, 0.2, 1),
          ),
          child: child,
        ),
      ),
    );
    _padOpening = false;
  }

  @override
  Widget build(BuildContext context) {
    if (engine.config == null) return const _BootView();

    final s = engine.status;
    final c = engine.config!;
    final live = s.running;

    return Scaffold(
      backgroundColor: T.bgDeep,
      body: LayoutBuilder(
        builder: (context, box) {
          // 整幅插画占据上半部（零裁切），下半部用原图底缘放大模糊延续，
          // 所以这里只决定"整幅图放在多高"，背景本身铺满全屏。
          final artH = math.min(
            box.maxWidth * _artRatio, // 390 → 551：按宽撑满，一点不裁
            box.maxHeight * 0.58,
          );

          return Stack(
            children: [
              // ── ① 全屏背景：**一整张壁纸**，铺满不留缝
              //
              //   bg_wall.jpg 已预先裁成 1080×2338（比例 0.4614 ≈ 屏幕 0.4619），
              //   所以运行时 cover 就是"刚好铺满、零二次裁切"。
              //   裁的是两侧各约 17%（背景建筑），人物纵向完整、脸全在。
              Positioned.fill(
                child: Image.asset(
                  'assets/bg/bg_wall.jpg',
                  fit: BoxFit.cover,
                  filterQuality: FilterQuality.low,
                  errorBuilder: (_, _, _) =>
                      const ColoredBox(color: T.bgDeep),
                ),
              ),

              // ── ①-b 极淡下坠：只在屏幕下半部加深，托住底部控件、
              //       上半部（人脸区）几乎不动，避免把人物盖住
              Positioned.fill(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [
                        Colors.transparent,
                        Colors.transparent,
                        const Color(0xFF07040F).withValues(alpha: 0.28),
                        const Color(0xFF07040F).withValues(alpha: 0.52),
                      ],
                      stops: const [0, 0.52, 0.78, 1],
                    ),
                  ),
                ),
              ),


              // ── ③ 界面层：全部浮在画上，靠线框和发光字读，不靠底色块
              Positioned.fill(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    // 标题压在画的左上（人物在右侧，不打架）
                    SafeArea(
                      bottom: false,
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(20, 18, 20, 0),
                        child: Align(
                          alignment: Alignment.topLeft,
                          child: InkTitle(
                            eyebrow: '',
                            title: _chapters[_chapter],
                          ),
                        ),
                      ),
                    ),

                    // 读数条：**骑在整幅图的下缘**（不是压在人物脸上）。
                    // 用 Spacer 把上半部让给插画，人脸的完整可见。
                    SizedBox(
                      height: math.max(0, artH - 116),
                    ),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(20, 7, 16, 9),
                      child: TapeStrip(
                        live: live,
                        // 顶部读数条只报**全局状态**，不重复各页控件已有的局部参数。
                        //
                        // 原先这里还有 SIZE / DIST / FOV 三项，已全部移除：
                        //  · SIZE / FOV —— 概览页两把刻度尺就在读数，重复；
                        //  · DIST       —— 概览的距离尺已删，读数条不该还念这个值
                        //                  （那是"功能没了、读数还在"的残留）。
                        items: [
                          ('STATUS',
                              live ? (s.hosted ? 'EXTEND' : 'MIRROR') : 'IDLE'),
                          ('FRAME', s.frames > 0 ? '${s.frames}' : '—'),
                          ('POSE', s.pose.tracking
                              ? '${s.pose.hz.toStringAsFixed(0)}Hz'
                              : 'WAIT'),
                          // CAP 是**实际捕获尺寸**（眼镜屏真实像素），
                          // 与画面页的「请求分辨率」不是同一件事，故保留，
                          // 但标签加「实获」以免和 1920/1600/1280 混淆。
                          ('CAP', s.capture.w > 0
                              ? '实获 ${s.capture.w}×${s.capture.h}'
                              : '实获 —'),
                        ],
                      ),
                    ),

                    // ── ④ 章节内容：透视线框，完全不加底色
                    Expanded(
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Expanded(
                            child: Stack(
                              children: [
                                Positioned.fill(
                                  child: SingleChildScrollView(
                                    padding: const EdgeInsets.fromLTRB(
                                        18, 0, 18, 92),
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.stretch,
                                      children: _content(s, c, live),
                                    ),
                                  ),
                                ),
                                Positioned(
                                  right: 16,
                                  bottom: 14,
                                  child: BevelButton(
                                    label: s.starting
                                        ? '启动中'
                                        : live
                                            ? 'STOP'
                                            : 'START',
                                    sub: s.starting
                                        ? '请稍候'
                                        : live
                                            ? '结束投映'
                                            : '开始投映',
                                    live: live,
                                    busy: s.starting,
                                    onTap: live ? engine.stop : engine.start,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          // ── ⑤ 右侧扇形导航
                          Padding(
                            padding: const EdgeInsets.only(
                                right: 4, bottom: 18),
                            child: Align(
                              alignment: Alignment.topCenter,
                              child: FanSlices(
                                labels: _chapters,
                                index: _chapter,
                                onTap: (i) => setState(() => _chapter = i),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  // ------------------------------------------------------------ 章节内容

  List<Widget> _content(EngineStatus s, EngineConfig c, bool live) =>
      switch (_chapter) {
        0 => _overview(s, c, live),
        1 => _display(s, c, live),
        2 => _pose(s, c, live),
        _ => _system(s, c, live),
      };

  /// 概览：一个大环形仪表（姿态）+ 一圈小读数 + 两组动作
  List<Widget> _overview(EngineStatus s, EngineConfig c, bool live) {
    return [
      if (engine.lastError != null)
        WireFrame(
          accent: T.red,
          alpha: 0.55,
          tint: 0.06,
          child: Row(
            children: [
              Expanded(
                child: Text(
                  engine.lastError!,
                  style: TextStyle(
                    fontFamily: T.mono,
                    fontSize: 8,
                    color: const Color(0xFFFFC2CE),
                    height: 1.5,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              GestureDetector(
                onTap: engine.clearError,
                child: Text(
                  '忽略',
                  style: TextStyle(
                    fontFamily: T.mono,
                    fontSize: 8,
                    color: A.petalA,
                    letterSpacing: 1.0,
                  ),
                ),
              ),
            ],
          ),
        ),

      // 姿态：环形 + 三列竖排读数（竖排文字，与扇形/线框呼应）
      WireFrame(
        accent: A.petalB,
        alpha: 0.40,
        child: Row(
          children: [
            ThinGauge(
              value: (s.pose.pitch + 30) / 60,
              label: 'PITCH',
              readout: s.pose.tracking
                  ? '${s.pose.pitch.toStringAsFixed(0)}°'
                  : '--',
              size: 84,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Row(
                children: [
                  Expanded(
                    child: _VertReadout(
                      label: 'YAW',
                      value: s.pose.tracking
                          ? s.pose.yaw.toStringAsFixed(1)
                          : '--',
                    ),
                  ),
                  Expanded(
                    child: _VertReadout(
                      label: 'ROLL',
                      value: s.pose.tracking
                          ? s.pose.roll.toStringAsFixed(1)
                          : '--',
                    ),
                  ),
                  Expanded(
                    child: _VertReadout(
                      label: 'HZ',
                      value: s.pose.tracking
                          ? s.pose.hz.toStringAsFixed(0)
                          : '--',
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),


      const SlashRule(label: 'ACTION'),

      // 两个动作：线框按钮，无实底。
      //
      // 这一行原本是三格（复位 / 校准 / 停稳），但「停稳」是**姿态页
      // 同一个 freeze 开关的第二个入口** —— 属于功能重复，已撤掉。
      // 撤掉后只剩两格，改成非对称权重：复位 3 : 校准 2。
      // 复位是高频操作（每次戴上眼镜几乎都要按），给更宽的点击区；
      // 校准是低频（只在零偏漂了才按）。
      Row(
        children: [
          Expanded(
            flex: 3,
            child: _WireAction(
              label: '复位',
              sub: '回正前方',
              enabled: live,
              onTap: engine.recenter,
            ),
          ),
          const SizedBox(width: 7),
          Expanded(
            flex: 2,
            child: _WireAction(
              label: '校准',
              sub: '零偏重来',
              enabled: s.pose.tracking,
              onTap: engine.recalibrate,
            ),
          ),
        ],
      ),

      const SlashRule(),

      // 空间参数：三把刻度尺
      WireFrame(
        accent: T.sky,
        alpha: 0.34,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            RulerSlider(
              label: 'SIZE 尺寸',
              readout: '${(0.3 + c.size / 100).toStringAsFixed(2)}×',
              value: c.size.toDouble(),
              min: 0,
              max: 170,
              divisions: 34,
              onChanged: (v) => engine.setParams(size: v.round()),
            ),
            const SizedBox(height: 3),
            RulerSlider(
              label: 'FOV 视场角',
              readout: '${15 + c.fov}°',
              value: c.fov.toDouble(),
              min: 0,
              max: 30,
              divisions: 30,
              onChanged: (v) => engine.setParams(fov: v.round()),
            ),
          ],
        ),
      ),

      if (!live)
        Padding(
          padding: const EdgeInsets.only(top: 8),
          child: Text(
            '首次会依次请求 USB 与录屏授权 · 弹窗需手动点「允许」',
            style: TextStyle(
              fontFamily: T.mono,
              fontSize: 7,
              color: T.ghost,
              height: 1.7,
              letterSpacing: 0.4,
            ),
          ),
        ),
    ];
  }

  /// 画面：形态选择（斜切芯片）+ 刻度尺 + 清晰度
  List<Widget> _display(EngineStatus s, EngineConfig c, bool live) {
    final canEdit = !live && !s.starting;
    return [
      const SlashRule(label: 'FORM'),
      // 形态只剩「镜像」一个值（扩展已删），所以不再做成按钮 ——
      // 单个可选值的芯片占满整行会很怪（看着像被拉长的按钮）。
      // 改成一行只读信息条：左边标签，右边当前值。
      WireFrame(
        accent: T.sky,
        alpha: 0.30,
        padding: const EdgeInsets.fromLTRB(10, 6, 10, 6),
        child: Row(
          children: [
            Text(
              'MODE  形态',
              style: TextStyle(
                fontFamily: T.sans,
                fontSize: 9,
                color: T.dim,
                letterSpacing: 1.2,
              ),
            ),
            const Spacer(),
            Text(
              '镜 像',
              style: TextStyle(
                fontFamily: T.mono,
                fontSize: 9.5,
                color: A.petalA,
                letterSpacing: 1.0,
                fontWeight: FontWeight.w600,
                shadows: [
                  Shadow(color: A.petalB.withValues(alpha: 0.55), blurRadius: 7),
                ],
              ),
            ),
          ],
        ),
      ),
      if (!canEdit)
        Padding(
          padding: const EdgeInsets.only(top: 5),
          child: Text(
            '运行中不可切换',
            style: TextStyle(
              fontFamily: T.mono,
              fontSize: 7,
              color: T.faint,
            ),
          ),
        ),
      if (c.hosted) ...[
        const SizedBox(height: 8),
        _WireAction(
          label: '目标应用',
          sub: c.label ?? '未选择',
          enabled: canEdit,
          onTap: () => showAppPicker(context, engine),
        ),
      ],

      const SlashRule(label: 'BEHAVIOR'),
      Row(
        children: [
          for (final m in const [
            ('悬停', 'hover'),
            ('追踪', 'track'),
          ]) ...[
            Expanded(
              child: _BevelChip(
                label: m.$1,
                selected: c.viewMode == m.$2,
                onTap: () => engine.setPose(viewMode: m.$2),
              ),
            ),
            if (m.$1 != '追踪') const SizedBox(width: 7),
          ],
        ],
      ),
      Padding(
        padding: const EdgeInsets.only(top: 7, left: 2),
        child: Text(
          _modeDesc(c.viewMode),
          style: TextStyle(
            fontFamily: T.mono,
            fontSize: 7.5,
            color: T.faint,
            height: 1.65,
          ),
        ),
      ),

      const SlashRule(label: 'RES 请求分辨率'),
      // 这三档是**请求**给眼镜的分辨率，不是实际拿到的画面尺寸。
      // 顶部读数条的「实获 W×H」才是真拿到的像素 —— 两者可能不一致
      // （眼镜有自己的原生分辨率，会做缩放）。所以这里明确写「请求」，
      // 并在顶部把 CAP 改成「实获」，避免被读成同一个数字的两处显示。
      Row(
        children: [
          for (var i = 0; i < 3; i++) ...[
            Expanded(
              child: _BevelChip(
                label: const ['请求 1920', '请求 1600', '请求 1280'][i],
                selected: c.resolution.clamp(0, 2) == i,
                onTap: () => engine.setResolution(i),
              ),
            ),
            if (i != 2) const SizedBox(width: 7),
          ],
        ],
      ),

    ];
  }

  /// 姿态：一个大方位盘 + 四轴刻度切换
  List<Widget> _pose(EngineStatus s, EngineConfig c, bool live) {
    final tracking = c.viewMode == 'track';
    return [
      const SlashRule(label: 'ORIENT'),
      WireFrame(
        accent: T.mint,
        alpha: 0.38,
        child: Row(
          children: [
            _CompassDial(
              yaw: s.pose.yaw,
              pitch: s.pose.pitch,
              roll: s.pose.roll,
              tracking: s.pose.tracking,
              size: 92,
            ),
            const SizedBox(width: 12),
            Expanded(
              // 原来这里是两个 _ToggleLine 的 Column；删掉只读的「跟随」灯后
              // 只剩一行，Column 会把它顶在顶部、下方留一大片空白。
              // 改成垂直居中，与左侧 92px 的方位盘视觉重心对齐。
              // 原先那段说明（跟随灯为什么被删）见 git 历史，这里不再留长注释。
              child: Center(
                child: _ToggleLine(
                  label: '静止停稳',
                  on: c.freeze,
                  onTap: () => engine.setPose(freeze: !c.freeze),
                ),
              ),
            ),
          ],
        ),
      ),

      if (tracking) ...[
        const SizedBox(height: 6),
        WireFrame(
          accent: T.wisteria,
          alpha: 0.30,
          child: RulerSlider(
            label: 'TAU 跟随时间常数',
            readout: '${c.followTau.toStringAsFixed(2)} s',
            value: c.followTau,
            min: 0.15,
            max: 1.5,
            divisions: 27,
            onChanged: (v) =>
                engine.setPose(followTau: (v * 100).round() / 100),
          ),
        ),
      ],

      const SlashRule(label: 'AXIS'),
      // 三轴：单行三格（YAW / PIT / ROL）。
      //
      // 原来这里是 2×2 四格，删掉「前后」之后变成 "1 + 2" 的两行，
      // 第一行只剩一个被 Expanded 拉满的格子 —— 看着像漏了一个。
      // 现在三个轴一行铺开，列宽一致、和上方的盘对齐。
      Row(
        children: [
          Expanded(
            child: _AxisCell(
              label: '左右',
              code: 'YAW',
              on: c.invertYaw,
              onTap: () => engine.setPose(invertYaw: !c.invertYaw),
            ),
          ),
          const SizedBox(width: 7),
          Expanded(
            child: _AxisCell(
              label: '上下',
              code: 'PIT',
              on: c.invertPitch,
              onTap: () => engine.setPose(invertPitch: !c.invertPitch),
            ),
          ),
          const SizedBox(width: 7),
          Expanded(
            child: _AxisCell(
              label: '竖直',
              code: 'ROL',
              on: c.invertRoll,
              onTap: () => engine.setPose(invertRoll: !c.invertRoll),
            ),
          ),
        ],
      ),
    ];
  }

  /// 系统：四格线框灯 + 采集 + 诊断（诊断默认收起）
  List<Widget> _system(EngineStatus s, EngineConfig c, bool live) {
    return [
      const SlashRule(label: 'SUBSYS'),
      // 三格灯一行（无障碍 / Shizuku / 眼镜）。
      // 原来是无障碍+Shizuku 一行、眼镜单独一行；删掉 IMU 之后就变成
      // "2 + 1" —— 最后一行只有一个格子被 Expanded 拉满，像掉了东西。
      Row(
        children: [
          Expanded(
            child: _WireLamp(
              label: '无障碍',
              on: s.accessibilityEnabled,
              onTap: engine.openAccessibilitySettings,
            ),
          ),
          const SizedBox(width: 7),
          Expanded(
            child: _WireLamp(
              label: 'Shizuku',
              on: s.shizukuReady,
              onTap: engine.requestShizuku,
            ),
          ),
          const SizedBox(width: 7),
          Expanded(
            child: _WireLamp(
              label: '眼镜',
              on: s.glasses,
              onTap: engine.refresh,
            ),
          ),
        ],
      ),

      const SlashRule(label: 'CAPTURE'),
      Row(
        children: [
          Expanded(
            child: _WireAction(
              label: '截图',
              sub: live ? '存 PNG' : '需投屏',
              enabled: live,
              onTap: () => _shot(context),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: _WireAction(
              label: s.shots.recording ? '停录' : '录像',
              sub: s.shots.recording ? '再点结束' : '存 MP4',
              enabled: live,
              onTap: () => _record(context),
              accent: s.shots.recording ? T.red : null,
            ),
          ),
        ],
      ),
      const SizedBox(height: 8),
      Row(
        children: [
          Expanded(
            child: _WireAction(
              label: '目录',
              sub: '打开',
              enabled: true,
              onTap: () => engine.openCaptureFolder(),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: _WireAction(
              label: '授权',
              sub: '申请',
              enabled: true,
              onTap: () => engine.ensurePermissions(),
            ),
          ),
        ],
      ),

      const SlashRule(label: 'DIAG'),
      _DiagFold(
        rows: [
          ('显示器', s.displayName),
          ('捕获', s.capture.w > 0
              ? '${s.capture.w}×${s.capture.h}'
              : '—'),
          // IMU 行已删除：IMU 功能键已从界面移除（用户要求），
          // 诊断里继续报它的帧数/发送模式就前后不一致了。
          // 姿态是否在追踪改由下方「零偏」「残差」两行体现。
          ('零偏', !s.pose.tracking
              ? '—'
              : s.pose.firstCal
                  ? '已完成'
                  : '校准中'),
          ('残差', s.pose.tracking
              ? '${s.pose.residualDps.toStringAsFixed(2)}°/s'
              : '—'),
          ('版本', c.version.isEmpty ? '—' : c.version),
        ],
      ),
    ];
  }

  static String _modeDesc(String v) => switch (v) {
        'track' => '画面被拖后一点再平滑滑回；歪头时自动摆正',
        'extend' => '不做 3DoF：画面固定贴眼前，等同外接屏',
        _ => '画面钉在空间里：转头时留在原处，会滑出视野',
      };

  Future<void> _shot(BuildContext context) async {
    final m = ScaffoldMessenger.maybeOf(context);
    // screenshotChecked 会在原生超时后再刷一次状态，
    // 用产物路径判断"其实已经存下来了"，避免"报失败但相册里有图"。
    final out = await engine.screenshotChecked();
    m?.showSnackBar(SnackBar(
      content: Text(out.message),
      duration: const Duration(seconds: 3),
    ));
  }

  Future<void> _record(BuildContext context) async {
    final m = ScaffoldMessenger.maybeOf(context);
    try {
      if (engine.status.shots.recording) {
        final p = await engine.recordStop();
        m?.showSnackBar(SnackBar(
          content: Text(p == null ? '录像已停止' : '录像已保存：$p'),
          duration: const Duration(seconds: 3),
        ));
      } else {
        final p = await engine.recordStart();
        m?.showSnackBar(SnackBar(
          content: Text(p == null ? '录像启动失败' : '开始录制：$p'),
          duration: const Duration(seconds: 3),
        ));
      }
    } catch (e) {
      m?.showSnackBar(SnackBar(content: Text('录像操作失败：$e')));
    }
  }
}

// =============================================================== 内部小组件

/// 竖排读数（标签竖着写，数值横着写）—— 与扇形导航的竖排语言一致
class _VertReadout extends StatelessWidget {
  const _VertReadout({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        RotatedBox(
          quarterTurns: 3,
          child: Text(
            label,
            style: TextStyle(
              fontFamily: T.mono,
              fontSize: 7,
              color: T.ghost,
              letterSpacing: 1.6,
            ),
          ),
        ),
        const SizedBox(height: 5),
        Text(
          value,
          style: TextStyle(
            fontFamily: T.mono,
            fontSize: 11,
            color: A.petalA,
            fontWeight: FontWeight.w600,
            shadows: [
              Shadow(color: A.petalB.withValues(alpha: 0.7), blurRadius: 9),
            ],
          ),
        ),
      ],
    );
  }
}

/// 线框动作块：无填充，只有描边 + 左对齐双行
class _WireAction extends StatelessWidget {
  const _WireAction({
    required this.label,
    required this.sub,
    required this.enabled,
    required this.onTap,
    this.accent,
  });

  final String label;
  final String sub;
  final bool enabled;
  final VoidCallback? onTap;
  final Color? accent;

  @override
  Widget build(BuildContext context) {
    final tone = accent ?? A.petalB;
    return GestureDetector(
      onTap: enabled ? onTap : null,
      child: AnimatedOpacity(
        duration: const Duration(milliseconds: 220),
        opacity: enabled ? 1 : 0.34,
        child: WireFrame(
          accent: tone,
          alpha: 0.42,
          tint: 0.045,
          padding: const EdgeInsets.fromLTRB(9, 8, 9, 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                label,
                style: TextStyle(
                  fontFamily: T.sans,
                  fontSize: 10,
                  color: enabled ? T.fg : T.dim,
                  letterSpacing: 0.8,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                sub,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontFamily: T.mono,
                  fontSize: 6.5,
                  color: T.faint,
                  letterSpacing: 0.3,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 斜切芯片：平行四边形选项，选中描边亮起，无实底
class _BevelChip extends StatelessWidget {
  const _BevelChip({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    // 色调固定：原先颜色芯片（红/青/黄）会用 accent 换色，
    // 那一整块已随亮度调节一起删掉，这里不再需要可变色调。
    final tone = A.petalB;
    return GestureDetector(
      onTap: onTap,
      child: GestureDetector(
        child: CustomPaint(
          painter: _ChipPainter(selected: selected, tone: tone),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 7),
            child: Center(
              child: Text(
                label,
                maxLines: 1,
                style: TextStyle(
                  fontFamily: T.mono,
                  fontSize: 9,
                  color: selected ? A.petalA : T.dim,
                  letterSpacing: 1.0,
                  fontWeight: selected ? FontWeight.w700 : FontWeight.w400,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _ChipPainter extends CustomPainter {
  _ChipPainter({required this.selected, required this.tone});

  final bool selected;
  final Color tone;

  @override
  void paint(Canvas canvas, Size size) {
    const lean = 7.0;
    final path = Path()
      ..moveTo(lean, 0)
      ..lineTo(size.width, 0)
      ..lineTo(size.width - lean, size.height)
      ..lineTo(0, size.height)
      ..close();

    if (selected) {
      canvas.drawPath(
        path,
        Paint()..color = tone.withValues(alpha: 0.14),
      );
      canvas.drawPath(
        path,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.2
          ..color = tone.withValues(alpha: 0.85),
      );
      canvas.drawPath(
        path,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 5
          ..color = tone.withValues(alpha: 0.20)
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 5),
      );
    } else {
      canvas.drawPath(
        path,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1
          ..color = T.wisteria.withValues(alpha: 0.22),
      );
    }
  }

  @override
  bool shouldRepaint(covariant _ChipPainter old) =>
      old.selected != selected || old.tone != tone;
}

/// 轴向格子：斜切 + 左上代号 + 右下状态
class _AxisCell extends StatelessWidget {
  const _AxisCell({
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
    return GestureDetector(
      onTap: onTap,
      child: CustomPaint(
        painter: _ChipPainter(
          selected: on,
          tone: on ? A.petalB : T.wisteria,
        ),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(11, 8, 9, 8),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      label,
                      style: TextStyle(
                        fontFamily: T.sans,
                        fontSize: 11,
                        color: on ? T.fg : T.dim,
                        letterSpacing: 0.5,
                        fontWeight:
                            on ? FontWeight.w600 : FontWeight.w400,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      code,
                      style: TextStyle(
                        fontFamily: T.mono,
                        fontSize: 7,
                        color: on ? A.petalA : T.ghost,
                        letterSpacing: 1.4,
                      ),
                    ),
                  ],
                ),
              ),
              _TinyLed(on: on),
            ],
          ),
        ),
      ),
    );
  }
}

/// 微型 LED：一个小方块，亮=薄荷，灭=暗紫
class _TinyLed extends StatelessWidget {
  const _TinyLed({required this.on});

  final bool on;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 7,
      height: 7,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(1.5),
        color: on ? T.mint : T.wisteria.withValues(alpha: 0.22),
        boxShadow: on ? T.glow(T.mint, blur: 8, alpha: 0.95) : null,
      ),
    );
  }
}

/// 线框状态灯：无填充，只有描边 + 左上小灯 + 名称
class _WireLamp extends StatelessWidget {
  const _WireLamp({
    required this.label,
    required this.on,
    required this.onTap,
  });

  final String label;
  final bool on;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: WireFrame(
        accent: on ? T.mint : T.wisteria,
        alpha: on ? 0.55 : 0.22,
        tint: on ? 0.055 : 0.02,
        padding: const EdgeInsets.fromLTRB(9, 8, 9, 8),
        child: Row(
          children: [
            _TinyLed(on: on),
            const SizedBox(width: 7),
            Expanded(
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontFamily: T.sans,
                  fontSize: 9.5,
                  color: on ? T.fg : T.dim,
                  letterSpacing: 0.4,
                ),
              ),
            ),
            Text(
              on ? 'ON' : 'OFF',
              style: TextStyle(
                fontFamily: T.mono,
                fontSize: 6.5,
                color: on ? T.mint : T.ghost,
                letterSpacing: 0.8,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 开关行：文字 + 斜切开关
class _ToggleLine extends StatelessWidget {
  const _ToggleLine({
    required this.label,
    required this.on,
    required this.onTap,
  });

  final String label;
  final bool on;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Row(
        children: [
          Expanded(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontFamily: T.sans,
                fontSize: 9.5,
                color: on ? T.fg : T.dim,
                letterSpacing: 0.5,
              ),
            ),
          ),
          const SizedBox(width: 6),
          Container(
            width: 30,
            height: 15,
            decoration: BoxDecoration(
              color: on
                  ? A.petalB.withValues(alpha: 0.22)
                  : T.wisteria.withValues(alpha: 0.07),
              border: Border.all(
                color: on
                    ? A.petalB.withValues(alpha: 0.70)
                    : T.wisteria.withValues(alpha: 0.20),
              ),
            ),
            child: Align(
              alignment: on ? Alignment.centerRight : Alignment.centerLeft,
              child: Container(
                width: 12,
                height: 15,
                color: on ? A.petalA : const Color(0xFF554A72),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 诊断折叠：一行摘要，点开铺开明细
class _DiagFold extends StatefulWidget {
  const _DiagFold({required this.rows});

  final List<(String, String)> rows;

  @override
  State<_DiagFold> createState() => _DiagFoldState();
}

class _DiagFoldState extends State<_DiagFold> {
  bool _open = false;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => setState(() => _open = !_open),
      child: WireFrame(
        accent: T.wisteria,
        alpha: _open ? 0.40 : 0.24,
        tint: 0.03,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Text(
                  _open ? '−' : '+',
                  style: TextStyle(
                    fontFamily: T.mono,
                    fontSize: 11,
                    color: A.petalA,
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  '诊断读数',
                  style: TextStyle(
                    fontFamily: T.sans,
                    fontSize: 9.5,
                    color: _open ? T.fg : T.dim,
                    letterSpacing: 0.6,
                  ),
                ),
                const Spacer(),
                Text(
                  '${widget.rows.length} 项',
                  style: TextStyle(
                    fontFamily: T.mono,
                    fontSize: 6.5,
                    color: T.ghost,
                  ),
                ),
              ],
            ),
            AnimatedSize(
              duration: const Duration(milliseconds: 280),
              curve: Curves.easeOutCubic,
              alignment: Alignment.topCenter,
              child: _open
                  ? Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          for (final r in widget.rows)
                            Padding(
                              padding: const EdgeInsets.only(bottom: 5),
                              child: Row(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  SizedBox(
                                    width: 52,
                                    child: Text(
                                      r.$1,
                                      style: TextStyle(
                                        fontFamily: T.mono,
                                        fontSize: 7,
                                        color: T.ghost,
                                        letterSpacing: 1.0,
                                      ),
                                    ),
                                  ),
                                  Expanded(
                                    child: Text(
                                      r.$2,
                                      style: TextStyle(
                                        fontFamily: T.mono,
                                        fontSize: 7.5,
                                        color: T.dim,
                                        height: 1.45,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                        ],
                      ),
                    )
                  : const SizedBox(width: double.infinity, height: 0),
            ),
          ],
        ),
      ),
    );
  }
}

/// 方位盘：随 roll 转天/地分界，随 pitch 上下偏移，细线圆环
class _CompassDial extends StatelessWidget {
  const _CompassDial({
    required this.yaw,
    required this.pitch,
    required this.roll,
    required this.tracking,
    required this.size,
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
      height: math.max(size, size),
      child: ClipOval(
        child: CustomPaint(
          painter: _CompassPainter(
            yaw: yaw.clamp(-90.0, 90.0),
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

class _CompassPainter extends CustomPainter {
  _CompassPainter({
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
    final k = tracking ? 1.0 : 0.4;

    canvas.save();
    canvas.translate(c.dx, c.dy);
    canvas.rotate(roll * math.pi / 180);

    final hy = -pitch * 1.6;

    // 天：极淡的粉
    canvas.drawRect(
      Rect.fromLTRB(-r, -r, r, hy),
      Paint()..color = A.petalB.withValues(alpha: 0.13 * k),
    );
    // 地：极淡的紫
    canvas.drawRect(
      Rect.fromLTRB(-r, hy, r, r),
      Paint()..color = T.wisteriaDeep.withValues(alpha: 0.16 * k),
    );

    // 地平线
    canvas.drawLine(
      Offset(-r, hy),
      Offset(r, hy),
      Paint()
        ..strokeWidth = 1.4
        ..color = A.petalA.withValues(alpha: 0.80 * k),
    );

    // 俯仰刻度
    for (var d = -20; d <= 20; d += 10) {
      if (d == 0) continue;
      final y = hy - d * 1.6;
      final half = d.abs() == 10 ? 10.0 : 17.0;
      canvas.drawLine(
        Offset(-half, y),
        Offset(half, y),
        Paint()
          ..strokeWidth = 1
          ..color = T.fg.withValues(alpha: 0.22 * k),
      );
    }
    canvas.restore();

    // 外圈细环
    canvas.drawCircle(
      c,
      r - 1,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.2
        ..color = T.mint.withValues(alpha: 0.45),
    );

    // 准星
    final cross = Paint()
      ..strokeWidth = 1.3
      ..color = A.petalA.withValues(alpha: 0.85);
    canvas.drawLine(c + const Offset(-7, 0), c + const Offset(7, 0), cross);
    canvas.drawLine(c + const Offset(0, -7), c + const Offset(0, 7), cross);

    // yaw 指针
    final a = -math.pi / 2 + (yaw * math.pi / 180) * 0.85;
    final p = c + Offset(math.cos(a) * (r - 4), math.sin(a) * (r - 4));
    canvas.drawCircle(p, 2.6, Paint()..color = T.sky);
  }

  @override
  bool shouldRepaint(covariant _CompassPainter old) =>
      old.yaw != yaw ||
      old.pitch != pitch ||
      old.roll != roll ||
      old.tracking != tracking;
}

class _BootView extends StatelessWidget {
  const _BootView();

  @override
  Widget build(BuildContext context) {
    return const ColoredBox(
      color: T.bgDeep,
      child: Center(child: OrbitLoader(size: 48, label: '连接引擎…')),
    );
  }
}
