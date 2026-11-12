import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:air4pro3dof/engine/engine_client.dart';
import 'package:air4pro3dof/pages/home_page.dart';
import 'package:air4pro3dof/theme/app_theme.dart';
import 'package:air4pro3dof/widgets/hud.dart';

/// 验证「尺寸 / 距离 / 视场角」三把刻度尺的拖动是否真的把值传下去。
/// 实测，不靠读代码断言。

const _font = r'C:\Windows\Fonts\simhei.ttf';

Future<void> _loadFont(String family) async {
  final f = File(_font);
  if (!f.existsSync()) return;
  final bytes = await f.readAsBytes();
  final loader = FontLoader(family)
    ..addFont(Future<ByteData>.value(
      ByteData.view(bytes.buffer, bytes.offsetInBytes, bytes.lengthInBytes),
    ));
  await loader.load();
}

class _Engine extends EngineModel {
  _Engine() {
    config = const EngineConfig(
      viewMode: 'hover',
      size: 34,
      distance: 14,
      fov: 32,
      followTau: 0.62,
      freeze: true,
    );
    status = const EngineStatus(
      running: true,
      glasses: true,
      frames: 100,
      mode: 'mirror',
      viewMode: 'hover',
      pose: PoseStatus(tracking: true, hz: 60),
      capture: CaptureStatus(w: 1080, h: 2400),
      version: '2.5.2',
    );
  }
}

void main() {
  setUpAll(() async {
    await _loadFont('Roboto');
    await _loadFont('monospace');
  });

  testWidgets('尺寸距离视场角刻度尺可拖动并下发', (tester) async {
    tester.view.physicalSize = const Size(390, 844) * 2.0;
    tester.view.devicePixelRatio = 2.0;
    addTearDown(tester.view.reset);

    final calls = <MethodCall>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('air4pro3dof/engine'),
      (call) async {
        calls.add(call);
        return null;
      },
    );
    addTearDown(() => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        const MethodChannel('air4pro3dof/engine'), null));

    final engine = _Engine();
    await tester.pumpWidget(MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: buildAppTheme(),
      darkTheme: buildAppTheme(),
      themeMode: ThemeMode.dark,
      home: HomePage(engine: engine),
    ));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    final rulers = find.byType(RulerSlider);
    debugPrint('SCALE_COUNT ${rulers.evaluate().length}');

    final before = engine.config!;
    debugPrint(
        'BEFORE size=${before.size} dist=${before.distance} fov=${before.fov}');

    for (var i = 0; i < rulers.evaluate().length; i++) {
      final sb = rulers.evaluate().elementAt(i);
      final rb = sb.renderObject is RenderBox ? sb.renderObject as RenderBox : null;
      if (rb == null || !rb.attached) {
        debugPrint('RULER $i NOT_ATTACHED');
        continue;
      }
      final sz = rb.size;
      final off = rb.localToGlobal(Offset.zero);
      debugPrint('RULER $i size=$sz origin=$off');

      await tester.ensureVisible(rulers.at(i));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      // 关键：ensureVisible 会滚动，必须**滚动之后**再取全局位置。
      // 之前用滚动前的 off 算坐标，导致点在 widget 上方 20px 处（y=650 vs 669.5）。
      final off2 = rb.localToGlobal(Offset.zero);
      final cx = off2.dx + sz.width * 0.7;
      final cy = off2.dy + sz.height - 11;
      debugPrint('RULER $i scrolled origin=$off2 tap ($cx,$cy)');

      // 直接 tapAt 到刻度条 70% 处（Listener.onPointerDown 立即 emit）
      // 先查这个点到底命中谁 —— 若被上层 widget 拦截，Listener 收不到事件
      final hit = tester.hitTestOnBinding(Offset(cx, cy));
      debugPrint('RULER $i hitTest 顶层: '
          '${hit.path.take(6).map((e) => e.target.runtimeType).toList()}');

      // Listener 到底在不在 RulerSlider 里？
      final listeners = find.descendant(
        of: rulers.at(i),
        matching: find.byType(Listener),
      );
      debugPrint('RULER $i 内部 Listener 数量: ${listeners.evaluate().length}');
      final gds = find.descendant(
        of: rulers.at(i),
        matching: find.byType(GestureDetector),
      );
      debugPrint('RULER $i 内部 GestureDetector 数量: ${gds.evaluate().length}');

      await tester.tapAt(Offset(cx, cy));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
    }

    final after = engine.config!;
    debugPrint(
        'AFTER size=${after.size} dist=${after.distance} fov=${after.fov}');

    final sp = calls.where((c) => c.method == 'setParams').toList();
    debugPrint('SETPARAMS_COUNT ${sp.length}');
    if (sp.isNotEmpty) debugPrint('LAST ${sp.last.arguments}');

    final changed = <String>[
      if (after.size != before.size) 'size(${before.size}->${after.size})',
      if (after.distance != before.distance)
        'distance(${before.distance}->${after.distance})',
      if (after.fov != before.fov) 'fov(${before.fov}->${after.fov})',
    ];
    debugPrint('CHANGED $changed');

    expect(sp, isNotEmpty, reason: '拖动必须触发 setParams 通道调用');
    expect(changed.length, greaterThanOrEqualTo(2),
        reason: '三把尺至少 2 个字段被改动，实际: $changed');
  });
}
