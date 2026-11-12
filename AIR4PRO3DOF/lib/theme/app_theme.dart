import 'package:flutter/material.dart';

/// ---------------------------------------------------------------------------
/// 设计令牌 —「夜桜 / Yozakura」二次元主题
///
/// 整体气质：深夜紫的天幕 + 樱花粉的霓虹，赛璐璐动画那种"实色块 + 亮描边"。
/// 保留原名（bg / fg / card / hair1 …）让所有页面零改动就吃上新配色，
/// 二次元专用的新令牌集中放在 `A` 里。
/// ---------------------------------------------------------------------------
class T {
  const T._();

  // ── 底色：深夜紫的三段夜
  /// 天幕顶色（最深）
  static const bgDeep = Color(0xFF07040F);

  /// 画布主底
  static const bg = Color(0xFF0E0A1A);

  /// 抬起面（卡片下垫一层，制造赛璐璐的分层）
  static const bgLift = Color(0xFF16102A);

  // ── 文字：月光白 → 紫灰
  static const fg = Color(0xFFF7F2FF);
  static const dim = Color(0xFFD5CBF0);
  static const faint = Color(0xFFA295C8);

  /// 行内代码 / 箭头 / 幽灵
  static const code = Color(0xFFBDB0E0);
  static const arrow = Color(0xFF7A6BA8);
  static const ghost = Color(0xFF6B5C94);

  /// 实心按钮上的字色（深紫近黑）
  static const ink = Color(0xFF0B0616);

  // ── 卡片：不用纯白叠加（那是无彩色），改成紫调半透明
  static const card = Color(0x14B48CFF);
  static const sunken = Color(0x0A8C6BFF);

  // ── 强调色：二次元常用的高饱和霓虹
  /// 樱花粉（主强调）
  static const sakura = Color(0xFFFF8FC7);
  static const sakuraLight = Color(0xFFFFB8DC);
  static const sakuraDeep = Color(0xFFE85BA4);

  /// 天蓝（次强调 / 科技感）
  static const sky = Color(0xFF7BD3F7);
  static const skyDeep = Color(0xFF3AA6D8);

  /// 薄荷绿（成功 / 在线）
  static const mint = Color(0xFF9FE8C8);
  static const mintDeep = Color(0xFF47C79B);

  /// 紫藤（第三强调 / 装饰）
  static const wisteria = Color(0xFFC39BFF);
  static const wisteriaDeep = Color(0xFF8B5CF6);

  /// 保留旧名，语义映射到新配色
  static const red = Color(0xFFFF6B8A);
  static const cyan = sky;
  static const amber = Color(0xFFFFD37B);

  // ── 描边：紫调发丝线（不用白，白会显脏）
  static Color hair(double a) => wisteria.withValues(alpha: a);
  static Color get hair1 => wisteria.withValues(alpha: 0.16);
  static Color get hair2 => wisteria.withValues(alpha: 0.09);
  static Color get hair3 => wisteria.withValues(alpha: 0.30);

  /// 樱花粉描边（用于强调元素）
  static Color get lineSakura => sakura.withValues(alpha: 0.42);

  // ── 发光（二次元的"霓虹味"全靠它，不是阴影而是光晕）
  static List<BoxShadow> glow(
    Color c, {
    double blur = 24,
    double spread = 0,
    double alpha = 0.45,
  }) =>
      [
        BoxShadow(
          color: c.withValues(alpha: alpha),
          blurRadius: blur,
          spreadRadius: spread,
        ),
      ];

  static List<BoxShadow> get glowSakura => [
        BoxShadow(
          color: sakura.withValues(alpha: 0.38),
          blurRadius: 28,
        ),
        BoxShadow(
          color: wisteriaDeep.withValues(alpha: 0.22),
          blurRadius: 44,
          spreadRadius: -8,
        ),
      ];

  // ── 几何：比原型更圆，二次元偏好大圆角
  static const rCard = 22.0;
  static const rStatus = 26.0;
  static const rSeg = 16.0;
  static const rBtn = 18.0;
  static const rMini = 12.0;
  static const rChip = 999.0;

  static const pad = 20.0;
  static const bodyBottom = 128.0;

  // ── 字体：中文优先用系统无衬线，读数用等宽
  static const mono = 'monospace';
  static const sans = 'Roboto';
}

/// ---------------------------------------------------------------------------
/// 二次元专用令牌（A = Anime）。与 T 分开，避免和旧命名冲突。
/// ---------------------------------------------------------------------------
class A {
  const A._();

  /// 樱花飘落的三种粉（由浅到深，画花瓣时随机取）
  static const petalA = Color(0xFFFFC2E0);
  static const petalB = Color(0xFFFF9CCB);
  static const petalC = Color(0xFFF57CB0);

  /// 渐变：卡片顶部的霓虹描边
  static const cardEdge = [Color(0xFFFF9CCB), Color(0xFFC39BFF), Color(0xFF7BD3F7)];

  /// 渐变：主按钮（樱花 → 紫藤）
  static const btnGrad = [Color(0xFFFFA3D4), Color(0xFFC39BFF)];

  /// 渐变：运行中的霓虹条
  static const liveGrad = [Color(0xFF7BD3F7), Color(0xFF9FE8C8), Color(0xFFC39BFF)];

  /// 卡片标准间距
  static const gap = 14.0;

  /// 描边宽度（赛璐璐风格比原来粗一点）
  static const stroke = 1.4;

  /// 圆角
  static const rPill = 999.0;
}

/// 等宽字（标签、数值、诊断行）
TextStyle tm(
  double size, {
  Color color = T.faint,
  double ls = 0,
  FontWeight weight = FontWeight.w400,
  double? height,
}) =>
    TextStyle(
      fontFamily: T.mono,
      fontSize: size,
      color: color,
      letterSpacing: ls,
      fontWeight: weight,
      height: height,
    );

/// 无衬线字（标题、正文）
TextStyle ts(
  double size, {
  Color color = T.fg,
  double ls = 0,
  FontWeight weight = FontWeight.w400,
  double? height,
}) =>
    TextStyle(
      fontFamily: T.sans,
      fontSize: size,
      color: color,
      letterSpacing: ls,
      fontWeight: weight,
      height: height,
    );

/// 带霓虹发光的标题字（二次元标题的标准做法：字色 + 同色光晕）
TextStyle tsGlow(
  double size, {
  Color color = T.fg,
  Color glowColor = A.petalB,
  double glow = 12,
  double ls = 0,
  FontWeight weight = FontWeight.w700,
  double? height,
}) =>
    TextStyle(
      fontFamily: T.sans,
      fontSize: size,
      color: color,
      letterSpacing: ls,
      fontWeight: weight,
      height: height,
      shadows: [
        Shadow(color: glowColor.withValues(alpha: 0.75), blurRadius: glow),
        Shadow(color: glowColor.withValues(alpha: 0.35), blurRadius: glow * 2.2),
      ],
    );

ThemeData buildAppTheme() {
  const scheme = ColorScheme.dark(
    primary: A.petalB,
    onPrimary: T.ink,
    primaryContainer: Color(0xFF2A1B45),
    onPrimaryContainer: T.fg,
    secondary: T.sky,
    onSecondary: T.ink,
    tertiary: T.mint,
    onTertiary: T.ink,
    tertiaryContainer: Color(0xFF17303A),
    onTertiaryContainer: T.mint,
    surface: T.bg,
    onSurface: T.fg,
    onSurfaceVariant: T.dim,
    outline: Color(0xFF3B2F5C),
    outlineVariant: Color(0xFF251C3C),
    error: T.red,
    onError: Colors.white,
    errorContainer: Color(0xFF3A1226),
    onErrorContainer: Color(0xFFFFB4C8),
  );

  final base = ThemeData(
    useMaterial3: true,
    brightness: Brightness.dark,
    colorScheme: scheme,
    scaffoldBackgroundColor: T.bg,
    canvasColor: T.bg,
    fontFamily: T.sans,
    // 二次元界面不用水波纹，交互反馈靠描边亮起与光晕
    splashFactory: NoSplash.splashFactory,
    highlightColor: Colors.transparent,
    hoverColor: A.petalA.withValues(alpha: 0.06),
  );

  return base.copyWith(
    textTheme: base.textTheme.apply(bodyColor: T.fg, displayColor: T.fg),
    iconTheme: const IconThemeData(color: T.fg, size: 20),
    dividerTheme: DividerThemeData(color: T.hair2, thickness: 1, space: 1),
    snackBarTheme: SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      backgroundColor: const Color(0xFF221839),
      contentTextStyle: ts(12.5, color: T.fg, height: 1.5),
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(T.rBtn),
        side: BorderSide(color: T.lineSakura),
      ),
      insetPadding: const EdgeInsets.fromLTRB(20, 0, 20, 116),
    ),
    bottomSheetTheme: const BottomSheetThemeData(
      backgroundColor: T.bg,
      surfaceTintColor: Colors.transparent,
      modalBackgroundColor: T.bg,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
        side: BorderSide(color: Color(0x3DFF9CCB)),
      ),
      dragHandleColor: Color(0x66FF9CCB),
    ),
    textSelectionTheme: TextSelectionThemeData(
      cursorColor: A.petalB,
      selectionColor: A.petalB.withValues(alpha: 0.28),
      selectionHandleColor: A.petalB,
    ),
    progressIndicatorTheme: const ProgressIndicatorThemeData(
      color: A.petalB,
      linearTrackColor: Color(0x1FC39BFF),
    ),
  );
}
