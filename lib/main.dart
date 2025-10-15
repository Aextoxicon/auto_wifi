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
import 'package:path_provider/path_provider.dart';

const String AUTH_HOST = '192.168.110.100';
//const String AUTH_HOST = '127.0.0.1:50000';
const String AUTH_PATH = '/drcom/login';
const String TEST_URL = 'http://www.msftconnecttest.com/connecttest.txt';
//const String TEST_URL = 'http://127.0.0.1:50000/local_connect_test';
const String CHANNEL_ID = 'autowifi_channel';
final logManager = LogManager();

// 日志管理
class LogManager extends ChangeNotifier {
  static final LogManager _instance = LogManager._internal();
  factory LogManager() => _instance;
  LogManager._internal();

  final List<String> _logs = [];
  static const int _maxLogs = 100;

  List<String> get logs => List.unmodifiable(_logs);

  // 标准日志方法
  void log(String message) {
    _logMessage(message, 'info');
  }

  // 错误日志方法
  void logError(String message, [StackTrace? stackTrace]) {
    _logMessage('[ERROR] $message', 'error', stackTrace);
  }

  // 警告日志方法
  void logWarning(String message) {
    _logMessage('[WARNING] $message', 'warning');
  }

  // 调试日志方法（仅在调试模式下输出）
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

    // 使用 Flutter 自带的 debugPrint（调试模式）
    if (kDebugMode) {
      debugPrint(logMessage);
    }

    // 使用 dart:developer 的 log 函数
    developer.log(
      message,
      name: 'AutoWIFI',
      level: _getLogLevel(level),
      time: DateTime.now(),
      sequenceNumber: _logs.length,
      stackTrace: stackTrace,
    );

    // 在 Release 模式下也输出关键错误
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

// 后台服务

@pragma('vm:entry-point')
Future<bool> _backgroundIsInternetOk() async {
  try {
    logManager.logDebug('后台认证 - 网络检测开始');
    final resp = await http
        .get(Uri.parse(TEST_URL), headers: {'Cache-Control': 'no-cache'})
        .timeout(const Duration(seconds: 5));
    final result =
        resp.statusCode == 200 && resp.body.trim() == 'Microsoft Connect Test';
    logManager.logDebug('后台认证 - 网络检测结果: $result (状态码: ${resp.statusCode})');
    return result;
  } catch (e, stack) {
    logManager.logWarning('后台认证 - 网络检测异常: $e');
    return false;
  }
}

@pragma('vm:entry-point')
Future<bool> _backgroundLogin(String username, String password) async {
  logManager.log('后台认证 - 尝试登录: $username');
  try {
    final loginUri = Uri.http(AUTH_HOST, AUTH_PATH, {
      'callback': 'dr1003',
      'DDDDD': username,
      'upass': password,
      '0MKKey': '123456',
      'R1': '0',
      'R3': '0',
      'R6': '0',
      'para': '00',
      'v6ip': '',
      'v': '3196',
    });
    final response = await http
        .get(loginUri)
        .timeout(const Duration(seconds: 8));

    final result =
        response.statusCode == 200 &&
        (response.body.contains('成功') || response.body.contains('"result":1'));

    if (result) {
      logManager.log('后台认证 - 登录成功');
    } else {
      logManager.logWarning('后台认证 - 登录失败，状态码: ${response.statusCode}');
    }

    logManager.logDebug(
      '后台认证 - 登录响应详情: ${response.statusCode}, 内容长度: ${response.body.length}',
    );
    return result;
  } catch (e, stack) {
    logManager.logError('后台认证 - 登录异常: $e', stack);
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
        .listen((_) {
          logManager.log('后台任务 - 收到停止服务指令，退出');
          timer?.cancel();
          service.stopSelf();
        })
        .onError((error, stack) {
          logManager.logError('监听停止服务指令时发生错误: $error', stack);
        });

    int normal = 0;
    int reconnect = 0;
    int fail = 0;

    logManager.log('后台任务 - 启动定时检测 (5秒周期)');
    timer = Timer.periodic(const Duration(seconds: 5), (_) async {
      logManager.logDebug('后台任务 - 定时检测循环开始');

      try {
        final username = prefs.getString('username') ?? '';
        final password = prefs.getString('password') ?? '';

        logManager.logDebug('后台任务 - 配置检查: 用户名存在=${username.isNotEmpty}');

        if (username.isEmpty || password.isEmpty) {
          logManager.logWarning('后台任务 - 配置为空，中止循环');
          service.invoke('updateCounters', {'status': '配置缺失'});
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
          ok = await _backgroundLogin(username, password);
          logManager.log('后台任务 - 登录完成: $ok');
          if (ok) {
            reconnect++;
          } else {
            fail++;
          }
        }

        consecutiveErrors = 0;

        logManager.logDebug('后台任务 - 发送状态更新');
        service.invoke('updateCounters', {
          'normal': normal,
          'reconnect': reconnect,
          'fail': fail,
          'status': netOk ? '网络正常' : (ok ? '重连成功' : '重连失败'),
        });
      } catch (e, stack) {
        consecutiveErrors++;
        logManager.logError(
          '后台任务发生错误 ($consecutiveErrors/$maxConsecutiveErrors): $e',
          stack,
        );

        if (consecutiveErrors >= maxConsecutiveErrors) {
          logManager.logError('后台任务连续错误过多，自动停止服务');
          service.invoke('updateCounters', {'status': '服务异常停止'});
          timer?.cancel();
          service.stopSelf();
        }
      }
    });
  } catch (e, stack) {
    logManager.logError('后台任务发生致命错误: $e', stack);
    try {
      service.invoke('updateCounters', {'status': '服务崩溃'});
    } catch (invokeError, invokeStack) {
      logManager.logError('调用 updateCounters 失败: $invokeError', invokeStack);
    }
    service.stopSelf();
  }
}

// 前端

Future<void> _initBackgroundService() async {
  final service = FlutterBackgroundService();

  if (Platform.isAndroid) {
    // 通知渠道配置
    final FlutterLocalNotificationsPlugin flutterLocalNotificationsPlugin =
        FlutterLocalNotificationsPlugin();
    const AndroidInitializationSettings initializationSettingsAndroid =
        AndroidInitializationSettings('@mipmap/ic_launcher');
    const InitializationSettings initializationSettings =
        InitializationSettings(android: initializationSettingsAndroid);
    await flutterLocalNotificationsPlugin.initialize(initializationSettings);

    const AndroidNotificationChannel channel = AndroidNotificationChannel(
      CHANNEL_ID,
      'Auto WIFI Service',
      description: '用于保持校园网连接的后台服务',
      importance: Importance.low,
    );
    await flutterLocalNotificationsPlugin
        .resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin
        >()
        ?.createNotificationChannel(channel);
  }

  await service.configure(
    androidConfiguration: AndroidConfiguration(
      onStart: backgroundTask,
      autoStart: false,
      isForegroundMode: true,
      notificationChannelId: CHANNEL_ID,
      initialNotificationTitle: 'Auto-WIFI',
      initialNotificationContent: '保持校园网连接',
      foregroundServiceTypes: [AndroidForegroundType.dataSync],
    ),
    iosConfiguration: IosConfiguration(),
  );
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  _initBackgroundService();
  runApp(const MyApp());
}

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

  final ValueNotifier<Map<String, dynamic>> _countersNotifier = ValueNotifier({
    'normal': 0,
    'reconnect': 0,
    'fail': 0,
  });

  void _listenBackgroundLogs() {
    // 监听日志更新
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

  @override
  void initState() {
    super.initState();
    _initPrefs();
    _listenBackgroundStatus();
    _listenBackgroundLogs();
    _checkServiceStatus();
  }

  Future<void> _checkServiceStatus() async {
    // 延迟检查服务状态，确保服务有时间启动
    await Future.delayed(const Duration(seconds: 1));
    final service = FlutterBackgroundService();
    if (await service.isRunning()) {
      setState(() => status = '后台已运行');
    }
  }

  void _listenBackgroundStatus() async {
    try {
      final service = FlutterBackgroundService();

      // 检查服务是否正在运行
      bool isRunning = await service.isRunning();
      if (isRunning) {
        setState(() => status = '后台已运行');
      }

      // 监听来自后台的更新
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

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('配置账号'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: userCtrl,
              decoration: const InputDecoration(labelText: '用户名'),
            ),
            TextField(
              controller: passCtrl,
              obscureText: true,
              decoration: const InputDecoration(labelText: '密码'),
            ),
          ],
        ),
        actions: [
          TextButton(onPressed: Navigator.of(ctx).pop, child: const Text('取消')),
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
              Navigator.pop(ctx);
            },
            child: const Text('保存'),
          ),
        ],
      ),
    );
  }

  void _startLoop() async {
    logManager.log('前台操作 - 尝试启动服务...');
    if (!configured || username.isEmpty || password.isEmpty) {
      logManager.logWarning('前台操作 - 启动失败：未配置账号');
      setState(() => status = '启动失败：请先配置账号');
      return;
    }

    try {
      final service = FlutterBackgroundService();

      if (await service.isRunning()) {
        logManager.log('前台操作 - 服务已在运行，中止启动');
        setState(() => status = '任务已在运行');
        return;
      }

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

  Future<void> _stopService() async {
    logManager.log('前台操作 - 尝试停止服务');
    final service = FlutterBackgroundService();
    if (await service.isRunning()) {
      service.invoke("stopService");
    }
    setState(() {
      status = '已停止';
    });
  }

  // 在 _DrcomAuthPageState 类中添加以下方法
  Future<void> _exportLogs() async {
    try {
      final logs = logManager.logs;
      if (logs.isEmpty) {
        if (mounted) {
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(const SnackBar(content: Text('没有日志可导出')));
        }
        return;
      }

      if (Platform.isAndroid) {
        // 注意：在较新的 Android 版本中，这个权限可能被忽略
        final status = await Permission.storage.request();
        if (!status.isGranted) {
          if (mounted) {
            ScaffoldMessenger.of(
              context,
            ).showSnackBar(const SnackBar(content: Text('未获得存储权限，无法导出日志')));
          }
          return;
        }
      }

      // 构建日志内容
      final logContent = logs.reversed.join('\n'); // 最新日志在前

      // 创建文件名
      final now = DateTime.now();
      final fileName =
          'autowifi_logs_${now.year}${now.month.toString().padLeft(2, '0')}${now.day.toString().padLeft(2, '0')}_${now.hour.toString().padLeft(2, '0')}${now.minute.toString().padLeft(2, '0')}${now.second.toString().padLeft(2, '0')}.txt';

      // 请求存储权限并保存文件
      if (Platform.isAndroid) {
        final directory = Directory('/storage/emulated/0/Documents');
        if (!await directory.exists()) {
          await directory.create(recursive: true);
        }

        final file = File('${directory.path}/$fileName');
        await file.writeAsString(logContent);

        if (mounted) {
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(SnackBar(content: Text('日志已保存至: ${file.path}')));
        }
      } else {
        // iOS 或其他平台使用临时目录
        final directory = await getTemporaryDirectory();
        final file = File('${directory.path}/$fileName');
        await file.writeAsString(logContent);

        if (mounted) {
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(SnackBar(content: Text('日志已保存至: ${file.path}')));
        }
      }

      logManager.log('日志已导出: $fileName');
    } catch (e, stack) {
      logManager.logError('导出日志失败: $e', stack);
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('导出失败: $e')));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Auto-WIFI (诊断版)')),
      body: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (!configured)
              const Text('请先配置账号', style: TextStyle(color: Colors.orange)),
            if (configured) Text('当前账号: $username'),
            const SizedBox(height: 16),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                ElevatedButton(
                  onPressed: _showConfigDialog,
                  child: const Text('配置'),
                ),
                ElevatedButton(
                  onPressed: !configured ? null : _startLoop,
                  child: const Text('开始任务'),
                ),
                ElevatedButton(
                  onPressed: _stopService,
                  style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
                  child: const Text('停止'),
                ),
                ElevatedButton(
                  onPressed: _exportLogs,
                  child: const Text('导出日志'),
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
          ],
        ),
      ),
    );
  }
}
