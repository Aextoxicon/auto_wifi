import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:http/http.dart' as http;
import 'package:flutter_background_service/flutter_background_service.dart';
import 'dart:developer' as developer;
import "package:android_intent_plus/android_intent.dart";

const String TEST_URL = 'http://www.msftconnecttest.com/connecttest.txt';
//const String TEST_URL = 'http://192.168.31.113:50000/local_connect_test';
const String CHANNEL_ID = 'autowifi_channel';
final logManager = LogManager();

// 初始化通知通道 
Future<void> _initNotificationChannel() async {
  if (Platform.isAndroid) {
    final plugin = FlutterLocalNotificationsPlugin();
    const initSettings = InitializationSettings(
      android: AndroidInitializationSettings('@mipmap/ic_launcher'),
    );
    await plugin.initialize(initSettings);

    const channel = AndroidNotificationChannel(
      CHANNEL_ID,
      'Auto WIFI Service',
      description: '用于保持校园网连接的后台服务',
      importance: Importance.high,
      playSound: false,
      enableVibration: false,
    );
    await plugin
        .resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin
        >()
        ?.createNotificationChannel(channel);
  }
}

// ====== 日志管理（全局使用，放在顶部） ======
class LogManager extends ChangeNotifier {
  static final LogManager _instance = LogManager._internal();
  factory LogManager() => _instance;
  LogManager._internal();

  final List<String> _logs = [];
  static const int _maxLogs = 100;

  List<String> get logs => List.unmodifiable(_logs);
  String getLatestLog() {
    if (_logs.isEmpty) return '';
    return _logs.last;
  }

  void log(String message) {
    _logMessage(message, 'info');
  }

  void logError(String message, [StackTrace? stackTrace]) {
    _logMessage('[ERROR] $message', 'error', stackTrace);
  }

  void logWarning(String message) {
    _logMessage('[WARNING] $message', 'warning');
  }

  void logDebug(String message) {
    if (kDebugMode) {
      _logMessage('[DEBUG] $message', 'debug');
    }
  }

  void _logMessage(String message, String level, [StackTrace? stackTrace]) {
    final timestamp = DateTime.now().toLocal().toString().substring(11, 19);
    final logMessage = '[$timestamp] $message';
    _logs.add(logMessage);
    if (_logs.length > _maxLogs) {
      _logs.removeAt(0);
    }
    notifyListeners();

    if (kDebugMode) {
      debugPrint(logMessage);
    }

    developer.log(
      message,
      name: 'AutoWIFI',
      level: _getLogLevel(level),
      time: DateTime.now(),
      sequenceNumber: _logs.length,
      stackTrace: stackTrace,
    );

    if (!kDebugMode && (level == 'error' || level == 'warning')) {
      print(logMessage);
    }
  }

  int _getLogLevel(String level) {
    switch (level) {
      case 'error':
        return 2000;
      case 'warning':
        return 1500;
      case 'debug':
        return 500;
      default:
        return 1000;
    }
  }
}

// ====== 应用入口（现在放在最前面） ======
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await _initNotificationChannel();
  runApp(const MyApp());
}

// ====== UI 部分 ======
class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Auto-WIFI',
      theme: ThemeData(primarySwatch: Colors.blue),
      home: const DrcomAuthPage(),
    );
  }
}

// 定义一个通用的 Dialog 路由
Route _createHeroDialogRoute(Widget dialog) {
  return PageRouteBuilder(
    // 将背景设置为透明
    opaque: false,
    // 允许 Hero 动画的正常执行
    pageBuilder: (context, animation, secondaryAnimation) => dialog,
    // 关键：确保不添加会覆盖 Hero 动画的默认转场效果
    transitionsBuilder: (context, animation, secondaryAnimation, child) {
      // 只保留 Hero 动画，或者添加一个淡入（FadeTransition）效果
      return FadeTransition(opacity: animation, child: child);
    },
  );
}

class DrcomAuthPage extends StatefulWidget {
  const DrcomAuthPage({super.key});

  @override
  State<DrcomAuthPage> createState() => _DrcomAuthPageState();
}

class _DrcomAuthPageState extends State<DrcomAuthPage> {
  late SharedPreferences prefs;
  bool configured = false;
  String username = '';
  String password = '';
  String status = '准备就绪';
  int time = 3;
  final ValueNotifier<Map<String, dynamic>> _countersNotifier = ValueNotifier({
    'normal': 0,
    'reconnect': 0,
    'fail': 0,
  });

  void _listenBackgroundLogs() {
    logManager.addListener(() {
      setState(() {});
    });
  }

  Future<void> _initPrefs() async {
    try {
      logManager.logDebug('前台操作 - 开始初始化 SharedPreferences');
      prefs = await SharedPreferences.getInstance();
      username = prefs.getString('username') ?? '';
      password = prefs.getString('password') ?? '';
      configured = username.isNotEmpty;
      setState(() {});
      logManager.log('前台操作 - SharedPreferences 初始化成功');
    } catch (e, stack) {
      logManager.logError('前台操作 - SharedPreferences 初始化失败: $e', stack);
    }
  }

  void _openBatteryOptimizationSettings() {
    try {
      final intent = AndroidIntent(
        action: 'android.settings.IGNORE_BATTERY_OPTIMIZATION_SETTINGS',
      );
      intent.launch();
    } catch (e) {
      showDialog(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('请手动关闭电池优化'),
          content: const Text(
            '为确保后台服务正常运行，请前往：\n'
            '设置 → 电池 → 电池优化 → 找到本应用 → 选择“不优化”',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text('我知道了'),
            ),
          ],
        ),
      );
    }
  }

  Future<void> _requestNotificationPermission() async {
    if (Platform.isAndroid) {
      final status = await Permission.notification.request();
      if (status.isDenied) {
        logManager.logWarning('未获得通知权限，可能影响后台服务运行。');
      }
    }
  }

  @override
  void initState() {
    super.initState();
    _initPrefs();
    _listenBackgroundStatus();
    _listenBackgroundLogs();
    _checkServiceStatus();
    _requestNotificationPermission();
    _checkBatteryOptimization();
  }

  Future<void> _checkBatteryOptimization() async {
    if (Platform.isAndroid) {
      try {
        final status = await Permission.ignoreBatteryOptimizations.status;
        if (!status.isGranted) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) _showBatteryOptimizationDialog();
          });
        }
      } catch (e) {
        logManager.logWarning('检查电池优化状态失败: $e');
      }
    }
  }

  void _showExitOptimizationDialog() {
    Navigator.of(context).push(
      _createHeroDialogRoute(
        Hero(
          tag: 'hero_exit_dialog',
          child: Material(
            type: MaterialType.transparency,
            child: Scaffold(
              backgroundColor: Theme.of(context).scaffoldBackgroundColor,
              // 构建全屏 UI
              appBar: AppBar(
                title: const Text('强制关闭服务'),
                leading: IconButton(
                  icon: const Icon(Icons.close),
                  onPressed: () => Navigator.of(context).pop(), // 关闭按钮
                ),
              ),
              body: Padding(
                padding: const EdgeInsets.all(20.0),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      '跳转到设置页面，点击强行停止以彻底停止此App以及后台服务，然后别忘了划掉后台窗口',
                      style: TextStyle(fontSize: 16),
                    ),
                    const Spacer(),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.end,
                      children: [
                        const SizedBox(width: 8),
                        ElevatedButton(
                          onPressed: () {
                            Navigator.of(context).pop();
                            _openAppSettings();
                          },
                          child: const Text('去设置'),
                        ),
                      ],
                    ),
                    const SizedBox(height: 20), // 留出底部边距
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  void _showBatteryOptimizationDialog() {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('请关闭电池优化'),
        content: const Text(
          '为确保后台服务正常运行，请前往:\n'
          '电池优化→找到本应用→选择不优化',
        ),
        actions: [
          TextButton(
            onPressed: Navigator.of(ctx).pop,
            child: const Text('稍后再说'),
          ),
          ElevatedButton(
            onPressed: () {
              Navigator.of(ctx).pop();
              _openBatteryOptimizationSettings();
            },
            child: const Text('去设置'),
          ),
        ],
      ),
    );
  }

  void _checkServiceStatus() async {
    try {
      final service = FlutterBackgroundService();
      bool isRunning = await service.isRunning();
      if (isRunning) {
        setState(() => status = '后台已运行');
      } else if (!isRunning) {
        logManager.log('前台操作 - 检测到服务未运行，尝试自动启动...');
        final prefs = await SharedPreferences.getInstance();
        final username = prefs.getString('username') ?? '';
        final password = prefs.getString('password') ?? '';
        if (username.isNotEmpty && password.isNotEmpty) {
          await _startLoop();
          await Future.delayed(const Duration(milliseconds: 500));
          bool nowRunning = await service.isRunning();
          setState(() => status = nowRunning ? '后台已运行' : '启动失败');
        } else {
          setState(() => status = '配置缺失，请先设置账号');
          logManager.logWarning('前台操作 - 配置缺失，无法自动启动服务。');
        }
      }
    } catch (e) {
      setState(() => status = '服务检查失败');
    }
  }

  void _listenBackgroundStatus() async {
    try {
      final service = FlutterBackgroundService();
      bool isRunning = await service.isRunning();
      if (isRunning) {
        setState(() => status = '后台已运行');
      }
      service
          .on('updateCounters')
          .listen((data) {
            if (data != null && data is Map) {
              final newStatus = data['status'] as String? ?? '运行中';
              if (status != newStatus) {
                setState(() => status = newStatus);
              }
              _countersNotifier.value = {
                'normal': data['normal'] as int? ?? 0,
                'reconnect': data['reconnect'] as int? ?? 0,
                'fail': data['fail'] as int? ?? 0,
              };
              final latestLog = data['latestLog'] as String?;
              if (latestLog != null && latestLog.isNotEmpty) {
                if (!logManager.logs.contains(latestLog)) {
                  logManager._logs.add(latestLog);
                  logManager.notifyListeners();
                }
              }
            }
          })
          .onError((error) {
            logManager.log('监听后台状态时发生错误: $error');
          });
    } catch (e) {
      logManager.log('初始化后台状态监听失败: $e');
    }
  }

  void _showConfigDialog() {
    final userCtrl = TextEditingController(text: username);
    final passCtrl = TextEditingController(text: password);
    final timeCtrl = TextEditingController(text: time.toString());
    // [修改] 使用自定义路由代替 showDialog
    Navigator.of(context).push(
      _createHeroDialogRoute(
        Hero(
          tag: 'hero_config_dialog',
          child: Material(
            type: MaterialType.transparency,
            child: Scaffold(
              backgroundColor: Theme.of(context).scaffoldBackgroundColor,

              appBar: AppBar(
                title: const Text('配置后台服务'),
                leading: IconButton(
                  icon: const Icon(Icons.close),
                  onPressed: () => Navigator.of(context).pop(),
                ),
              ),

              body: Padding(
                padding: const EdgeInsets.all(24.0),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    TextField(
                      controller: userCtrl,
                      decoration: const InputDecoration(labelText: '用户名'),
                    ),
                    const SizedBox(height: 16),
                    TextField(
                      controller: passCtrl,
                      obscureText: true,
                      decoration: const InputDecoration(labelText: '密码'),
                    ),

                    const Spacer(),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.end,
                      children: [
                        const SizedBox(width: 8),
                        ElevatedButton(
                          onPressed: () {
                            final u = userCtrl.text.trim();
                            final p = passCtrl.text.trim();
                            prefs.setString('username', u);
                            prefs.setString('password', p);
                            setState(() {
                              username = u;
                              password = p;
                              configured = u.isNotEmpty;
                            });

                            _forceStopAllServices();
                            Navigator.of(context).pop();
                          },
                          child: const Text('保存'),
                        ),
                      ],
                    ),
                    const SizedBox(height: 16), // 底部填充
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  bool serviceInitialized = false;
  Future<void> _startLoop() async {
    logManager.log('前台操作 - 尝试启动服务...');
    if (!configured || username.isEmpty || password.isEmpty) {
      logManager.logWarning('前台操作 - 启动失败：未配置账号');
      setState(() => status = '启动失败：请先配置账号');
      return;
    }
    try {
      if (!serviceInitialized) {
        await _initBackgroundService();
        serviceInitialized = true;
      }
      final service = FlutterBackgroundService();
      if (Platform.isAndroid) {
        logManager.log('前台操作 - 准备启动后台服务');
        final started = await service.startService();
        setState(() {
          status = started ? '启动中...' : '启动失败：系统拒绝';
        });
        if (mounted) {
          final message = started ? '后台服务启动命令已发送。' : '启动失败：系统拒绝。';
          logManager.log('前台操作 - $message');
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(SnackBar(content: Text(message)));
        }
      }
      _countersNotifier.value = {'normal': 0, 'reconnect': 0, 'fail': 0};
    } catch (e, stack) {
      logManager.logError('前台操作 - 启动服务时发生异常: $e', stack);
      setState(() => status = '启动失败：发生异常');
    }
  }

  Future<void> _openAppSettings() async {
    if (Platform.isAndroid) {
      try {
        final intent = AndroidIntent(
          action: 'android.settings.APPLICATION_DETAILS_SETTINGS',
          data: 'package:com.example.auto_wifi',
        );
        await intent.launch();
      } catch (e) {
        logManager.logError('打开应用设置失败: $e');
      }
    }
  }

  Future<void> _forceStopAllServices() async {
    try {
      final service = FlutterBackgroundService();
      if (await service.isRunning()) {
        service.invoke("stopService");
        await Future.delayed(const Duration(milliseconds: 300));
      }
      if (Platform.isAndroid) {
        final plugin = FlutterLocalNotificationsPlugin();
        await plugin.cancelAll();
      }
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('已停止所有服务,再次启动服务以应用配置')));
      }
    } catch (e, stack) {
      logManager.logError('强制停止服务时发生异常: $e', stack);
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('强制停止服务失败: $e')));
      }
    }
  }

  Future<void> _immediateLogin() async {
    logManager.log('前台操作 - 立即登录');
    try {
      final prefs = await SharedPreferences.getInstance();
      final username = prefs.getString('username') ?? '';
      final password = prefs.getString('password') ?? '';
      if (username.isEmpty || password.isEmpty) {
        if (mounted) {
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(const SnackBar(content: Text('请先配置账号和密码')));
        }
        return;
      }
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('正在登录...')));
      }
      bool result = await _backgroundLogin(username, password);
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(result ? '登录成功' : '登录失败')));
      }
      logManager.log('前台操作 - 立即登录${result ? '成功' : '失败'}');
    } catch (e, stack) {
      logManager.logError('前台操作 - 立即登录异常: $e', stack);
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('登录异常: $e')));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Auto-WIFI')),
      body: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            if (!configured)
              const Text('请先配置账号', style: TextStyle(color: Colors.orange)),
            if (configured) Text('当前账号: $username'),
            const SizedBox(height: 16),
            Column(
              children: [
                Hero(
                  tag: 'hero_config_dialog',
                  createRectTween: (begin, end) {
                    // 强制 Hero 沿直线路径飞行
                    return RectTween(begin: begin, end: end);
                  },
                  child: SizedBox(
                    width: MediaQuery.of(context).size.width * 0.6,
                    child: ElevatedButton(
                      onPressed: _showConfigDialog,
                      child: const Text('配置'),
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                SizedBox(
                  width: MediaQuery.of(context).size.width * 0.6,
                  child: ElevatedButton(
                    onPressed: !configured ? null : _startLoop,
                    child: const Text('开始任务'),
                  ),
                ),
                const SizedBox(height: 8),
                Hero(
                  tag: 'hero_exit_dialog',
                  createRectTween: (begin, end) {
                    // 强制 Hero 沿直线路径飞行
                    return RectTween(begin: begin, end: end);
                  },
                  child: SizedBox(
                    width: MediaQuery.of(context).size.width * 0.6,
                    child: ElevatedButton(
                      onPressed: _showExitOptimizationDialog,
                      child: const Text('跳转设置强行停止APP'),
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                SizedBox(
                  width: MediaQuery.of(context).size.width * 0.6,
                  child: ElevatedButton(
                    onPressed: !configured ? null : _immediateLogin,
                    child: const Text('立即登录'),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 20),
            Text(
              '运行状态: $status',
              style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 10),
            ValueListenableBuilder<Map<String, dynamic>>(
              valueListenable: _countersNotifier,
              builder: (context, counters, child) {
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '网络正常: ${counters['normal']} 次',
                      style: const TextStyle(fontSize: 14),
                    ),
                    Text(
                      '重连成功: ${counters['reconnect']} 次',
                      style: const TextStyle(fontSize: 14),
                    ),
                    Text(
                      '重连失败: ${counters['fail']} 次',
                      style: const TextStyle(fontSize: 14),
                    ),
                  ],
                );
              },
            ),
            const Spacer(),
            Align(
              alignment: Alignment.bottomCenter,
              child: Padding(
                padding: const EdgeInsets.only(top: 16.0),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: const [
                    Text(
                      'by Aextoxicon&Qwen-coder',
                      style: TextStyle(fontSize: 12, color: Colors.grey),
                    ),
                    Text(
                      'powered by Flutter',
                      style: TextStyle(fontSize: 12, color: Colors.grey),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ====== 后台服务初始化（UI 之后） ======
Future<void> _initBackgroundService() async {
  final service = FlutterBackgroundService();
  await service.configure(
    androidConfiguration: AndroidConfiguration(
      onStart: backgroundTask,
      autoStart: true,
      isForegroundMode: true,
      notificationChannelId: CHANNEL_ID,
      initialNotificationTitle: 'Auto-WIFI',
      initialNotificationContent: '保持校园网连接',
      foregroundServiceTypes: [AndroidForegroundType.dataSync],
    ),
    iosConfiguration: IosConfiguration(),
  );
}

// ====== 后台任务逻辑（全部移到最后） ======
Future<bool> _backgroundLogin(String username, String password) async {
  logManager.log('后台认证 - 尝试登录: $username');
  try {
    String url =
        'http://192.168.110.100/drcom/login?callback=dr1003&DDDDD=$username&upass=$password&0MKKey=123456&R1=0&R3=0&R6=0&para=00&v6ip=&v=3196';
    final loginUri = Uri.parse(url);
    logManager.logDebug('后台认证 - 请求 URL: $loginUri');
    final response = await http
        .get(
          loginUri,
          headers: {
            'User-Agent': 'curl/7.88.1',
            'Accept': '*/*',
            'Connection': 'close',
          },
        )
        .timeout(const Duration(seconds: 8));

    logManager.logDebug(
      '后台认证 - 响应状态: ${response.statusCode}, 内容: ${response.body}',
    );

    final result =
        response.statusCode == 200 &&
        (response.body.contains('"result":1') ||
            response.body.contains('dr1003({"result":1}'));

    if (result) {
      logManager.log('后台认证 - 登录成功');
    } else {
      logManager.logWarning('后台认证 - 登录失败');
    }
    return result;
  } catch (e, stack) {
    logManager.logError('后台认证 - 登录异常: $e', stack);
    return false;
  }
}

Future<bool> _backgroundIsInternetOk() async {
  try {
    logManager.logDebug('后台认证 - 网络检测开始');
    final resp = await http
        .get(Uri.parse(TEST_URL), headers: {'Cache-Control': 'no-cache'})
        .timeout(Duration(seconds: 1));
    final result =
        resp.statusCode == 200 && resp.body.trim() == 'Microsoft Connect Test';
    logManager.logDebug('后台认证 - 网络检测结果: $result (状态码: ${resp.statusCode})');
    return result;
  } catch (e, stack) {
    logManager.logWarning('后台认证 - 网络检测异常: $e');
    final prefs = await SharedPreferences.getInstance();
    String username = prefs.getString('username') ?? '';
    String password = prefs.getString('password') ?? '';
    await _backgroundLogin(username, password);
    return false;
  }
}

@pragma('vm:entry-point')
Future<void> backgroundTask(ServiceInstance service) async {
  logManager.log('后台任务 - 启动');
  Timer? timer;
  int consecutiveErrors = 0;
  const maxConsecutiveErrors = 3;

  try {
    logManager.logDebug('后台任务 - 获取 SharedPreferences 实例');
    final prefs = await SharedPreferences.getInstance();
    logManager.logDebug('后台任务 - SharedPreferences 实例获取成功');

    service
        .on('stopService')
        .listen((_) async {
          logManager.log('后台任务 - 收到停止服务指令，正在退出...');
          timer?.cancel();
          try {
            service.invoke('updateCounters', {
              'status': '服务已停止',
              'latestLog': logManager.getLatestLog(),
            });
          } catch (e) {
            logManager.logError('发送最终状态更新失败: $e');
          }
          await Future.delayed(const Duration(milliseconds: 100));
          service.stopSelf();
        })
        .onError((error, stack) {
          logManager.logError('监听停止服务指令时发生错误: $error', stack);
        });

    int normal = 0;
    int reconnect = 0;
    int fail = 0;

    logManager.log('后台任务 - 启动定时检测 (默认3秒周期)');
    timer = Timer.periodic(Duration(seconds: 2), (_) async {
      logManager.logDebug('后台任务 - 定时检测循环开始');
      try {
        final username = prefs.getString('username') ?? '';
        final password = prefs.getString('password') ?? '';
        logManager.logDebug('后台任务 - 配置检查: 用户名存在=${username.isNotEmpty}');
        if (username.isEmpty || password.isEmpty) {
          logManager.logWarning('后台任务 - 配置为空，中止循环');
          service.invoke('updateCounters', {
            'status': '配置缺失',
            'latestLog': logManager.getLatestLog(),
          });
          return;
        }

        logManager.logDebug('后台任务 - 开始网络检测');
        bool netOk = await _backgroundIsInternetOk();
        logManager.logDebug('后台任务 - 网络检测完成: $netOk');

        bool ok = false;
        if (netOk) {
          normal++;
          logManager.log('后台任务 - 网络正常，计数增加');
        } else {
          logManager.log('后台任务 - 网络异常，开始登录');
          bool loginResult = await _backgroundLogin(username, password);
          if (loginResult) {
            reconnect++;
            ok = true;
          } else {
            fail++;
            ok = false;
          }
        }

        consecutiveErrors = 0;
        service.invoke('updateCounters', {
          'normal': normal,
          'reconnect': reconnect,
          'fail': fail,
          'status': netOk ? '网络正常' : (ok ? '重连成功' : '重连失败'),
          'latestLog': logManager.getLatestLog(),
        });
      } catch (e, stack) {
        consecutiveErrors++;
        logManager.logError(
          '后台任务发生错误 ($consecutiveErrors/$maxConsecutiveErrors): $e',
          stack,
        );
        if (consecutiveErrors >= maxConsecutiveErrors) {
          logManager.logError('后台任务连续错误过多，自动停止服务');
          service.invoke('updateCounters', {
            'status': '服务异常停止',
            'latestLog': logManager.getLatestLog(),
          });
          timer?.cancel();
          service.stopSelf();
        }
        try {
          service.invoke('updateCounters', {
            'status': '任务错误',
            'latestLog': logManager.getLatestLog(),
          });
        } catch (_) {}
      }
    });
  } catch (e, stack) {
    logManager.logError('后台任务发生致命错误: $e', stack);
    try {
      service.invoke('updateCounters', {
        'status': '服务崩溃',
        'latestLog': logManager.getLatestLog(),
      });
    } catch (invokeError, invokeStack) {
      logManager.logError('调用 updateCounters 失败: $invokeError', invokeStack);
    }
    service.stopSelf();
  }
}