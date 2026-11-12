import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// 原生引擎（`GlassEngine.java`）的 Dart 侧门面。
///
/// 只做三件事：把状态流翻译成强类型模型、把用户操作转成 MethodChannel 调用、
/// 维护一份界面用的诊断日志。所有会话逻辑都在原生侧，UI 不持有任何引擎状态。

class PoseStatus {
  const PoseStatus({
    this.tracking = false,
    this.yaw = 0,
    this.pitch = 0,
    this.roll = 0,
    this.hz = 0,
    this.frozen = false,
    this.biasDps = 0,
    this.residualDps = 0,
    this.firstCal = false,
  });

  final bool tracking;
  final double yaw;
  final double pitch;
  final double roll;
  final double hz;
  final bool frozen;

  /// IMU 自身的估计零偏（三轴最大，°/s）。数值大不代表在漂，它是被减掉的那部分。
  final double biasDps;

  /// 静止窗口内的残差（°/s）。这才是"还会不会漂"的指标，收敛后接近噪声底。
  final double residualDps;

  /// 首次零偏校准是否完成。false 时画面**一定**还带单向漂移——
  /// 这不是 bug，是还没校完：需要戴着眼镜连续 0.6 秒不动。
  final bool firstCal;

  factory PoseStatus.fromMap(Map<Object?, Object?> m) => PoseStatus(
        tracking: m['tracking'] == true,
        yaw: _d(m['yaw']),
        pitch: _d(m['pitch']),
        roll: _d(m['roll']),
        hz: _d(m['hz']),
        frozen: m['frozen'] == true,
        biasDps: _d(m['biasDps']),
        residualDps: _d(m['residualDps']),
        firstCal: m['firstCal'] == true,
      );
}

class CaptureStatus {
  const CaptureStatus({this.wantW = 0, this.wantH = 0, this.w = 0, this.h = 0});

  final int wantW;
  final int wantH;
  final int w;
  final int h;

  bool get matches => w > 0 && w == wantW && h == wantH;

  factory CaptureStatus.fromMap(Map<Object?, Object?> m) => CaptureStatus(
        wantW: _i(m['wantW']),
        wantH: _i(m['wantH']),
        w: _i(m['w']),
        h: _i(m['h']),
      );
}

class ImuStatus {
  const ImuStatus({this.open = false, this.frames = 0, this.sendMode = ''});

  final bool open;
  final int frames;
  final String sendMode;

  factory ImuStatus.fromMap(Map<Object?, Object?> m) => ImuStatus(
        open: m['open'] == true,
        frames: _i(m['frames']),
        sendMode: (m['sendMode'] as String?) ?? '',
      );
}

/// 画面模式解析：原生正常发字符串；旧包/异常情况可能发 int，这里一并兼容，
/// 避免一个字段类型不对就把整个界面卡在启动页。
String _viewModeOf(Object? v) {
  if (v is String) {
    return v == 'track' || v == 'extend' ? v : 'hover';
  }
  if (v is int) return v == 1 ? 'track' : (v == 2 ? 'extend' : 'hover');
  return 'hover';
}

/// 截图 / 录像状态（原生侧 `shots` 字段）。
class ShotsStatus {
  const ShotsStatus({
    this.recording = false,
    this.lastPath,
    this.dir = '',
    this.permissionNote = '',
  });

  final bool recording;

  /// 最近一次截图 / 录像的落盘路径。
  final String? lastPath;

  /// 截图与录像所在目录（应用专属外部目录）。
  final String dir;

  /// 最近一次运行时权限申请的结果，形如 "POST_NOTIFICATIONS=OK"。
  final String permissionNote;

  bool get hasLast => lastPath != null && lastPath!.isNotEmpty;

  factory ShotsStatus.fromMap(Map<Object?, Object?> m) => ShotsStatus(
        recording: m['recording'] == true,
        lastPath: (m['lastPath'] as String?)?.isEmpty == true
            ? null
            : m['lastPath'] as String?,
        dir: (m['dir'] as String?) ?? '',
        permissionNote: (m['permissionNote'] as String?) ?? '',
      );
}

class EngineStatus {
  const EngineStatus({
    this.running = false,
    this.starting = false,
    this.glasses = false,
    this.displayName = '—',
    this.displayId = -1,
    this.stageReady = false,
    this.stageLaunched = false,
    this.presentation = false,
    this.frames = 0,
    this.frameIdleMs = 0,
    this.aspect = 1,
    this.mode = 'mirror',
    this.viewMode = 'hover',
    this.hidReady = false,
    this.component,
    this.label,
    this.pose = const PoseStatus(),
    this.capture = const CaptureStatus(),
    this.imu = const ImuStatus(),
    this.shots = const ShotsStatus(),
    this.accessibilityEnabled = false,
    this.canInject = false,
    this.shizukuInstalled = false,
    this.shizukuReady = false,
    this.error,
    this.version = '',
  });

  final bool running;
  final bool starting;
  final bool glasses;
  final String displayName;
  final int displayId;
  final bool stageReady;
  final bool stageLaunched;
  final bool presentation;
  final int frames;

  /// 距离上一次收到投屏帧过了多少毫秒（0 = 正在出帧或未运行）。
  final int frameIdleMs;

  /// 画面是否可能已停更（>10 秒没新帧）。
  bool get frameStalled => frameIdleMs > 10000;
  final double aspect;
  final String mode;

  /// 画面行为：hover（悬停）/ track（追踪）/ extend（扩展）。
  final String viewMode;

  /// 眼镜 HID 是否已连上（含"待机连接"：没开始悬停也能调亮度）。
  final bool hidReady;
  final String? component;
  final String? label;
  final PoseStatus pose;
  final CaptureStatus capture;
  final ImuStatus imu;

  /// 截图 / 录像状态。
  final ShotsStatus shots;
  final bool accessibilityEnabled;
  final bool canInject;
  final bool shizukuInstalled;
  final bool shizukuReady;
  final String? error;
  final String version;

  bool get hosted => mode == 'hosted';

  bool get canInjectInput => shizukuReady || canInject;

  factory EngineStatus.fromMap(Map<Object?, Object?> m) {
    final pose = m['pose'];
    final capture = m['capture'];
    final imu = m['imu'];
    final a11y = m['accessibility'];
    final shizuku = m['shizuku'];
    final shots = m['shots'];
    return EngineStatus(
      running: m['running'] == true,
      starting: m['starting'] == true,
      glasses: m['glasses'] == true,
      displayName: (m['displayName'] as String?) ?? '—',
      displayId: _i(m['displayId']),
      stageReady: m['stageReady'] == true,
      stageLaunched: m['stageLaunched'] == true,
      presentation: m['presentation'] == true,
      frames: _i(m['frames']),
      aspect: _d(m['aspect'], 1),
      mode: (m['mode'] as String?) ?? 'mirror',
      viewMode: _viewModeOf(m['viewMode']),
      hidReady: m['hidReady'] == true,
      component: m['component'] as String?,
      label: m['label'] as String?,
      pose: pose is Map ? PoseStatus.fromMap(pose) : const PoseStatus(),
      capture: capture is Map ? CaptureStatus.fromMap(capture) : const CaptureStatus(),
      imu: imu is Map ? ImuStatus.fromMap(imu) : const ImuStatus(),
      shots: shots is Map ? ShotsStatus.fromMap(shots) : const ShotsStatus(),
      accessibilityEnabled: a11y is Map && a11y['enabled'] == true,
      canInject: a11y is Map && a11y['canInject'] == true,
      shizukuInstalled: shizuku is Map && shizuku['installed'] == true,
      shizukuReady: shizuku is Map && shizuku['ready'] == true,
      error: (m['error'] as String?)?.isEmpty == true ? null : m['error'] as String?,
      version: (m['version'] as String?) ?? '',
    );
  }
}

class EngineConfig {
  const EngineConfig({
    this.size = 70,
    this.distance = 15,
    this.fov = 8,
    this.resolution = 1,
    this.freeze = true,
    this.invertForward = false,
    this.invertYaw = false,
    this.invertPitch = false,
    this.invertRoll = false,
    this.mode = 'mirror',
    this.compat = false,
    this.trusted = true,
    this.viewMode = 'hover',
    this.followTau = 0.4,
    this.panelLevel = 6,
    this.color = 0,
    this.component,
    this.label,
    this.version = '',
  });

  final int size;
  final int distance;
  final int fov;
  final int resolution;
  final bool freeze;
  final bool invertForward;
  final bool invertYaw;
  final bool invertPitch;
  final bool invertRoll;
  final String mode;
  final bool compat;
  final bool trusted;

  /// 画面行为：hover（悬停）/ track（追踪）/ extend（扩展）。
  final String viewMode;

  /// 跟随时间常数（秒），越大越"懒"。
  final double followTau;

  /// 面板档位（1~10）：只在开始悬停后可用（需要会话的 HID 连接下发）。
  final int panelLevel;

  /// 临时色彩档：0=关，11/12/13=红/青/黄。不跨会话保留（原生侧不存盘）。
  final int color;
  final String? component;
  final String? label;
  final String version;

  bool get hosted => mode == 'hosted';

  /// 是否处于色彩模式（整屏单色）。
  bool get colorMode => color != 0;


  EngineConfig copyWith({
    int? size,
    int? distance,
    int? fov,
    int? resolution,
    bool? freeze,
    bool? invertForward,
    bool? invertYaw,
    bool? invertPitch,
    bool? invertRoll,
    String? mode,
    bool? compat,
    bool? trusted,
    String? viewMode,
    double? followTau,
    int? panelLevel,
    int? color,
    String? component,
    String? label,
  }) =>
      EngineConfig(
        size: size ?? this.size,
        distance: distance ?? this.distance,
        fov: fov ?? this.fov,
        resolution: resolution ?? this.resolution,
        freeze: freeze ?? this.freeze,
        invertForward: invertForward ?? this.invertForward,
        invertYaw: invertYaw ?? this.invertYaw,
        invertPitch: invertPitch ?? this.invertPitch,
        invertRoll: invertRoll ?? this.invertRoll,
        mode: mode ?? this.mode,
        compat: compat ?? this.compat,
        trusted: trusted ?? this.trusted,
        viewMode: viewMode ?? this.viewMode,
        followTau: followTau ?? this.followTau,
        panelLevel: panelLevel ?? this.panelLevel,
        color: color ?? this.color,
        component: component ?? this.component,
        label: label ?? this.label,
        version: version,
      );

  factory EngineConfig.fromMap(Map<Object?, Object?> m) => EngineConfig(
        size: _i(m['size'], 70),
        distance: _i(m['distance'], 15),
        fov: _i(m['fov'], 8),
        resolution: _i(m['resolution'], 1),
        freeze: m['freeze'] != false,
        invertForward: m['invertForward'] == true,
        invertYaw: m['invertYaw'] == true,
        invertPitch: m['invertPitch'] == true,
        invertRoll: m['invertRoll'] == true,
        mode: (m['mode'] as String?) ?? 'mirror',
        compat: m['compat'] == true,
        trusted: m['trusted'] != false,
        viewMode: _viewModeOf(m['viewMode']),
        followTau: _d(m['followTau'], 0.4),
        panelLevel: _i(m['panelLevel'], 6).clamp(1, 10),
        color: _i(m['color'], 0),
        component: m['component'] as String?,
        label: m['label'] as String?,
        version: (m['version'] as String?) ?? '',
      );
}

class AppEntry {
  const AppEntry(this.label, this.component);

  final String label;
  final String component;

  factory AppEntry.fromMap(Map<Object?, Object?> m) =>
      AppEntry((m['label'] as String?) ?? '', (m['component'] as String?) ?? '');
}

class LogLine {
  LogLine(this.text) : at = DateTime.now();

  final String text;
  final DateTime at;

  String get clock =>
      '${at.hour.toString().padLeft(2, '0')}:${at.minute.toString().padLeft(2, '0')}:${at.second.toString().padLeft(2, '0')}';
}

class EngineModel extends ChangeNotifier {
  EngineModel();

  static const MethodChannel _channel = MethodChannel('air4pro3dof/engine');
  static const EventChannel _statusChannel = EventChannel('air4pro3dof/status');

  EngineConfig? config;
  EngineStatus status = const EngineStatus();
  final List<LogLine> logs = <LogLine>[];

  /// 会话启动后由首页消费：置 true 表示「该弹出触控板了」。
  bool padRequested = false;

  /// 一次性提示（toast），由 UI 取走并清空。
  String? pendingToast;
  String? lastError;


  StreamSubscription? _sub;
  bool loading = false;
  bool _started = false;

  Future<void> init() async {
    if (_started) return;
    _started = true;
    loading = true;
    notifyListeners();

    _channel.setMethodCallHandler(_onNativeCall);
    try {
      final raw = await _channel.invokeMethod<Map<Object?, Object?>>('getConfig');
      if (raw != null) {
        config = EngineConfig.fromMap(raw);
      }
    } on PlatformException catch (e) {
      lastError = e.message;
    } catch (e) {
      // 解析失败也不能把界面卡死：退回默认配置并显示错误，用户可以重试
      lastError = '读取配置失败：$e';
    }
    config ??= const EngineConfig();

    _sub = _statusChannel.receiveBroadcastStream().listen((event) {
      if (event is Map) {
        try {
          status = EngineStatus.fromMap(event);
        } catch (e) {
          lastError = '状态解析失败：$e';
          notifyListeners();
          return;
        }
        if (status.error != null) lastError = status.error;
        notifyListeners();
      }
    }, onError: (Object e) {
      lastError = '状态通道断开：$e';
      notifyListeners();
    });

    loading = false;
    notifyListeners();
  }

  Future<dynamic> _onNativeCall(MethodCall call) async {
    switch (call.method) {
      case 'onToast':
        pendingToast = call.arguments as String?;
        notifyListeners();
        break;
      case 'onError':
        lastError = call.arguments as String?;
        notifyListeners();
        break;
      case 'onSessionStarted':
        // 只有扩展屏模式才需要触控板；镜像整屏时手机不参与交互
        padRequested = config?.hosted ?? false;
        notifyListeners();
        break;
      case 'onSessionStopped':
        padRequested = false;
        notifyListeners();
        break;
    }
    return null;
  }

  void addLog(String text) {
    logs.insert(0, LogLine(text));
    if (logs.length > 120) logs.removeLast();
  }

  void consumeToast() => pendingToast = null;

  void clearError() {
    lastError = null;
    _channel.invokeMethod('dismissError');
    notifyListeners();
  }

  void consumePadRequest() => padRequested = false;

  /// 重新拉一次配置（"重新检测"按钮用）：状态流本身每 800ms 自己刷。
  Future<void> refresh() async {
    try {
      final raw = await _channel.invokeMethod<Map<Object?, Object?>>('getConfig');
      if (raw != null) {
        config = EngineConfig.fromMap(raw);
      }
    } on PlatformException catch (e) {
      lastError = e.message;
    }
    notifyListeners();
  }

  // ---------------- 操作

  Future<void> start() async {
    final c = config;
    if (c == null) return;
    lastError = null;
    await _channel.invokeMethod('start', {
      'mode': c.mode,
      'component': c.component,
      'label': c.label,
      'compat': c.compat,
      'trusted': c.trusted,
    });
    notifyListeners();
  }

  Future<void> stop() async {
    await _channel.invokeMethod('stop');
    notifyListeners();
  }

  Future<void> setParams({int? size, int? distance, int? fov}) async {
    if (config == null) return;
    config = config!.copyWith(size: size, distance: distance, fov: fov);
    notifyListeners();
    await _channel.invokeMethod('setParams', {
      'size': config!.size,
      'distance': config!.distance,
      'fov': config!.fov,
    });
  }

  Timer? _panelTimer;
  int? _pendingPanel;

  /// 面板档位：1~10 是亮度，11/12/13 是红/青/黄色彩。
  ///
  /// 拖动时每帧都触发，而每次下发都是一次 USB 传输（最坏 300ms），
  /// 所以做 140ms 尾触发——松手后必然发出最后一档。
  Future<void> setPanelLevel(int level) async {
    if (config == null) return;
    final lv = level.clamp(1, 13);
    config = config!.copyWith(
      panelLevel: lv <= 10 ? lv : config!.panelLevel,
      color: lv > 10 ? lv : 0,
    );
    notifyListeners();
    _pendingPanel = lv;
    _panelTimer?.cancel();
    _panelTimer = Timer(const Duration(milliseconds: 140), () {
      final v = _pendingPanel;
      _pendingPanel = null;
      if (v != null) _channel.invokeMethod('setPanel', {'level': v});
    });
  }

  Future<void> setResolution(int level) async {
    if (config == null) return;
    config = config!.copyWith(resolution: level);
    notifyListeners();
    await _channel.invokeMethod('setResolution', {'level': level});
  }

  Future<void> setPose({
    bool? freeze,
    bool? invertForward,
    bool? invertYaw,
    bool? invertPitch,
    bool? invertRoll,
    String? viewMode,
    double? followTau,
  }) async {
    if (config == null) return;
    config = config!.copyWith(
      freeze: freeze,
      invertForward: invertForward,
      invertYaw: invertYaw,
      invertPitch: invertPitch,
      invertRoll: invertRoll,
      viewMode: viewMode,
      followTau: followTau,
    );
    notifyListeners();
    await _channel.invokeMethod('setPose', {
      'freeze': config!.freeze,
      'invertForward': config!.invertForward,
      'invertYaw': config!.invertYaw,
      'invertPitch': config!.invertPitch,
      'invertRoll': config!.invertRoll,
      'viewMode': config!.viewMode,
      'followTau': config!.followTau,
    });
  }

  Future<void> setMode(String mode) async {
    if (config == null) return;
    config = config!.copyWith(mode: mode);
    notifyListeners();
  }

  Future<void> setCompat(bool value) async {
    if (config == null) return;
    config = config!.copyWith(compat: value);
    notifyListeners();
  }

  Future<void> setTrusted(bool value) async {
    if (config == null) return;
    config = config!.copyWith(trusted: value);
    notifyListeners();
  }

  Future<void> setHostedApp(AppEntry app) async {
    if (config == null) return;
    config = config!.copyWith(component: app.component, label: app.label);
    notifyListeners();
    await _channel.invokeMethod('launchHosted', {
      'component': app.component,
      'label': app.label,
    });
  }

  Future<List<AppEntry>> listApps() async {
    try {
      final raw = await _channel.invokeMethod<List<Object?>>('listApps');
      if (raw == null) return const [];
      return raw
          .whereType<Map>()
          .map((e) => AppEntry.fromMap(e))
          .where((e) => e.component.contains('/'))
          .toList();
    } on PlatformException catch (e) {
      lastError = e.message;
      notifyListeners();
      return const [];
    }
  }

  Future<void> openAccessibilitySettings() =>
      _channel.invokeMethod('openAccessibilitySettings');

  Future<void> requestShizuku() => _channel.invokeMethod('requestShizuku');

  Future<void> recenter() => _channel.invokeMethod('recenter');

  /// 手动重连画面：重建眼镜端 Stage，连带重建 SurfaceTexture、扩展屏与目标应用。
  Future<void> reviveStage() => _channel.invokeMethod('reviveStage');

  /// 重新采样零偏（不动画面中位）。零偏估偏或温漂变大后手动触发。
  Future<void> recalibrate() => _channel.invokeMethod('recalibrate');

  // ------------------------------------------------------------ 截图 / 录像

  /// 截一张「眼镜里看到的画面」的 PNG。返回落盘路径；失败抛 PlatformException。
  Future<String?> screenshot() => _channel.invokeMethod<String>('screenshot');

  /// 截图，并区分"失败"与"其实成功了但回传晚了一步"。
  ///
  /// 为什么需要这个包装：原生侧截图要经过 glReadPixels + 像素搬运 + 编码 +
  /// 写文件，慢设备上可能超过轮询窗口，于是返回超时错误 ——
  /// **但文件其实已经落盘了**。用户看到"失败"提示，相册里却有新图，
  /// 这是典型的"报错但成功"。
  ///
  /// 这里的处理：出错时如果 `shots.lastPath` 已经是新文件（原生侧成功时
  /// 会先写 lastCapturePath 再 result.success，超时路径不写，所以主要靠
  /// 相册列表刷新来判断），就把那句"失败"改写成"可能已保存"。
  /// 判断依据不猜：直接看拉到的产物路径是否非空且比调用前更新。
  Future<ShotOutcome> screenshotChecked() async {
    final before = status.shots.lastPath;
    try {
      final p = await screenshot();
      if (p != null && p.isNotEmpty) {
        return ShotOutcome(path: p, success: true);
      }
      // 返回空值：可能是真超时，也可能只是回传晚了
      await refresh();
      final after = status.shots.lastPath;
      if (after != null && after.isNotEmpty && after != before) {
        return ShotOutcome(path: after, success: true);
      }
      return const ShotOutcome(path: null, success: false);
    } catch (e) {
      // 抛异常同理：先刷新再看有没有新产物
      await refresh();
      final after = status.shots.lastPath;
      if (after != null && after.isNotEmpty && after != before) {
        return ShotOutcome(path: after, success: true);
      }
      return ShotOutcome(path: null, success: false, error: '$e');
    }
  }

  /// 开始录像（MP4，录的是眼镜端渲染结果）。返回文件路径。
  Future<String?> recordStart() => _channel.invokeMethod<String>('recordStart');

  /// 停止录像并落盘 + 登记相册。返回文件路径。
  Future<String?> recordStop() => _channel.invokeMethod<String>('recordStop');

  /// 打开截图 / 录像所在目录。
  Future<void> openCaptureFolder() => _channel.invokeMethod('openCaptureFolder');

  /// 一次性申请截图 / 录像 / 通知需要的运行时权限。
  Future<void> ensurePermissions() => _channel.invokeMethod('ensurePermissions');

  /// 画面卡死时杀掉目标应用进程并重拉（需要 Shizuku 或已授权的 adb）。
  Future<String?> killHosted() => _channel.invokeMethod<String>('killHosted');

  Future<void> setCursor({double? u, double? v, bool? visible}) => _channel
      .invokeMethod('setCursor', {'u': u, 'v': v, 'visible': visible});

  Future<void> tap({bool longPress = false}) =>
      _channel.invokeMethod('tap', {'longPress': longPress});

  Future<void> scroll({required int axis, required int dir}) =>
      _channel.invokeMethod('scroll', {'axis': axis, 'dir': dir});

  Future<void> key(int code) => _channel.invokeMethod('key', {'code': code});


  @override
  void dispose() {
    _sub?.cancel();
    _channel.setMethodCallHandler(null);
    super.dispose();
  }
}

int _i(Object? v, [int fallback = 0]) => v is num ? v.toInt() : fallback;

double _d(Object? v, [double fallback = 0]) => v is num ? v.toDouble() : fallback;


/// 截图结果：区分真的失败和文件其实已写成、只是回传晚了一步。
///
/// 为什么不用裸 String?：裸返回值只能表达有路径/没路径，
/// 而截图失败有两种完全不同的语义 —— 画面没在渲染（真失败）、
/// 编码写盘慢了（假失败但产物已存在）。后者若报错，用户会以为丢了图。
class ShotOutcome {
  const ShotOutcome({required this.path, required this.success, this.error});

  final String? path;
  final bool success;
  final String? error;

  /// 给 UI 用的一句话结论。
  String get message {
    if (success && path != null && path!.isNotEmpty) return '已保存：';
    if (error != null) return '截图超时：画面可能没在出帧（相册里若有新图则说明已保存）';
    return '截图超时：画面可能没在出帧（相册里若有新图则说明已保存）';
  }
}
