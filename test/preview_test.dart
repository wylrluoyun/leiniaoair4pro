import 'dart:async';
import 'dart:math' as math;
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:air4pro3dof/engine/engine_client.dart';
import 'package:air4pro3dof/pages/home_page.dart';
import 'package:air4pro3dof/theme/app_theme.dart';
import 'package:air4pro3dof/widgets/hud.dart';

/// ---------------------------------------------------------------------------
/// 「DECK」界面预览图生成器
///
/// 与上一版的关键改动：**直接渲染真正的 HomePage**，不再手工复刻背景栈。
/// 上一版因为要手工镜像布局，出了两张"实际不存在"的图。
/// HomePage 的所有状态都从 EngineModel 派生，所以只要注入一个假 engine
/// 就等价于真机首帧。
///
/// 运行：
///   flutter test test/preview_test.dart --update-goldens
/// 输出：test/goldens/{overview,display,pose,system}.png
/// ---------------------------------------------------------------------------

const Size _kScene = Size(390, 844);

/// 本机字体。simhei 覆盖 GB2312 全集，中英日都能出字；
/// `monospace` 家族必须也加载它 —— `tm()` 用的就是 monospace，
/// 只加载 Consolas 会让所有等宽中文变方块。
const _sansCandidates = [
  r'C:\Windows\Fonts\simhei.ttf',
  r'C:\Windows\Fonts\Deng.ttf',
];
const _monoCandidates = [
  r'C:\Windows\Fonts\simhei.ttf',
];

Future<void> _loadFont(String family, List<String> candidates) async {
  for (final path in candidates) {
    final f = File(path);
    if (!f.existsSync()) continue;
    final bytes = await f.readAsBytes();
    final loader = FontLoader(family)
      ..addFont(Future<ByteData>.value(
        ByteData.view(bytes.buffer, bytes.offsetInBytes, bytes.lengthInBytes),
      ));
    await loader.load();
    return;
  }
}

/// 把背景图真正装进全局 ImageCache 并等它解码完。
///
/// 不能用 `ui.instantiateImageCodec`：它只建 codec 对象，不往 ImageCache 塞东西；
/// `Image.asset` 走的是 `AssetImage.resolve()` + ImageCache 那套，两者不通。
/// 且必须包在 `tester.runAsync` 里 —— 图片解码是真 IO，fake async 的 pump 推不动。
Future<void> _warmImage(WidgetTester tester, String asset) async {
  await tester.runAsync(() async {
    final stream = AssetImage(asset).resolve(ImageConfiguration.empty);
    final done = Completer<void>();
    final listener = ImageStreamListener(
      (_, _) {
        if (!done.isCompleted) done.complete();
      },
      onError: (Object e, StackTrace? s) {
        if (!done.isCompleted) done.completeError(e, s);
      },
    );
    stream.addListener(listener);
    try {
      await done.future.timeout(const Duration(seconds: 10));
    } finally {
      stream.removeListener(listener);
    }
  });
}

/// 预览用的 EngineModel 替身。
///
/// `EngineModel` 的 config / status / pendingToast / lastError / padRequested
/// 都是**公开字段**，所以继承后直接赋值，不 `implements`（那要覆盖 40+ 方法）。
/// 不调 init()：它会走 MethodChannel，测试环境会抛 MissingPluginException。
class _PreviewEngine extends EngineModel {
  _PreviewEngine({EngineConfig? cfg, EngineStatus? st}) {
    config = cfg ??
        const EngineConfig(
          viewMode: 'hover',
          size: 34,
          distance: 14,
          fov: 32,
          followTau: 0.62,
          freeze: true,
        );
    status = st ??
        const EngineStatus(
          running: true,
          glasses: true,
          displayName: 'RayNeo AR Glasses · 1920×1080',
          displayId: 5,
          stageReady: true,
          presentation: true,
          frames: 3821,
          frameIdleMs: 0,
          mode: 'mirror',
          viewMode: 'hover',
          hidReady: true,
          pose: PoseStatus(
            tracking: true,
            frozen: false,
            hz: 60,
            yaw: 8.4,
            pitch: -2.1,
            roll: 1.6,
          ),
          capture: CaptureStatus(w: 1080, h: 2400),
          accessibilityEnabled: true,
          canInject: true,
          version: '2.5.2',
        );
  }
}

/// 把 HomePage 包进一个能截图的最小宿主。
///
/// 为什么要 MaterialApp + Scaffold 两层：HomePage 自己返回 Scaffold，
/// 但 `ScaffoldMessenger.of` 需要 MaterialApp 祖先，
/// 而 golden 对 `find.byType(Material)` 截图时层级太深会截到错的节点，
/// 所以统一截 `find.byType(HomePage)` 的祖先 RepaintBoundary。
Widget _host(EngineModel engine) {
  return MaterialApp(
    debugShowCheckedModeBanner: false,
    theme: buildAppTheme(),
    darkTheme: buildAppTheme(),
    themeMode: ThemeMode.dark,
    home: HomePage(engine: engine),
  );
}

void main() {
  setUpAll(() async {
    await _loadFont('Roboto', _sansCandidates);
    await _loadFont('monospace', _monoCandidates);
  });

  /// 四个章节各出一张图。HomePage 内部按 spine 选章节，
  /// 所以这里通过点击书脊（SpineRail）切换，而不是重建 widget ——
  /// 这样截出来的是**真实的章节切换结果**，包括折叠态的保留。
  final cases = <(String, int)>[
    ('overview', 0),
    ('display', 1),
    ('pose', 2),
    ('system', 3),
  ];

  for (final c in cases) {
    testWidgets('生成 DECK 预览：${c.$1}', (tester) async {
      tester.view.physicalSize = _kScene * 2.0;
      tester.view.devicePixelRatio = 2.0;
      addTearDown(tester.view.reset);

      await _warmImage(tester, 'assets/bg/bg_wall.jpg');

      final engine = _PreviewEngine();
      await tester.pumpWidget(_host(engine));

      // ⚠️ 不能 pumpAndSettle：SakuraFall 是永不停止的 repeat 动画，
      // settle 永远等不到静止。用固定 pump 序列：
      //   pump()        → 让首帧落地
      //   pump(300ms)   → 走完 ArtBand / 折叠初始化
      //   pump(100ms)   → 让樱花在时间轴上有个非零时刻（否则花瓣都停在 y=0）
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      // 切到目标章节：FanSlices 现在是「整块一个手势 + 按角度反解扇区」，
      // 所以不能按子 widget 索引点，要**直接点在对应扇区的角度上**。
      if (c.$2 > 0) {
        final fanRect = tester.getRect(find.byType(FanSlices));
        // 复刻 FanSlices.angleFor：起点正左（π），顺时针
        const n = 4;
        final theta = math.pi + (c.$2 + 0.5) * (2 * math.pi / n);
        final r = fanRect.width / 2 * 0.60; // 落在扇区中部，避开中心点
        await tester.tapAt(Offset(
          fanRect.center.dx + math.cos(theta) * r,
          fanRect.center.dy + math.sin(theta) * r,
        ));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 340));
      }

      await tester.pump(const Duration(milliseconds: 100));

      await expectLater(
        find.byType(HomePage),
        matchesGoldenFile('goldens/deck-${c.$1}.png'),
      );
    });
  }
}
