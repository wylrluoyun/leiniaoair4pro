import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'engine/engine_client.dart';
import 'pages/home_page.dart';
import 'theme/app_theme.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
  // 界面是纯深色本体：状态栏/导航栏图标固定用浅色，避免亮色背景下看不见
  SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(
    statusBarColor: Colors.transparent,
    statusBarIconBrightness: Brightness.light,
    statusBarBrightness: Brightness.dark,
    systemNavigationBarColor: Colors.transparent,
    systemNavigationBarIconBrightness: Brightness.light,
    systemNavigationBarDividerColor: Colors.transparent,
  ));
  runApp(const Air4Pro3DofApp());
}

class Air4Pro3DofApp extends StatefulWidget {
  const Air4Pro3DofApp({super.key});

  @override
  State<Air4Pro3DofApp> createState() => _Air4Pro3DofAppState();
}

class _Air4Pro3DofAppState extends State<Air4Pro3DofApp> {
  final EngineModel _engine = EngineModel();

  @override
  void dispose() {
    _engine.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'AIR4PRO3DOF',
      debugShowCheckedModeBanner: false,
      // 只有一套深色主题：投屏时手机当遥控器，亮底会刺眼
      theme: buildAppTheme(),
      darkTheme: buildAppTheme(),
      themeMode: ThemeMode.dark,
      // 系统字号放大到 1.4 倍为止：再大滑块与列表会溢出，是版式与无障碍的折中
      builder: (context, child) => MediaQuery.withClampedTextScaling(
        maxScaleFactor: 1.4,
        child: child ?? const SizedBox.shrink(),
      ),
      home: HomePage(engine: _engine),
    );
  }
}
