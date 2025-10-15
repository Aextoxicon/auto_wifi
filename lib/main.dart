import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:http/http.dart' as http;
import 'package:flutter_background_service/flutter_background_service.dart';

const String AUTH_HOST = '192.168.110.100';
const String AUTH_PATH = '/drcom/login';
const String TEST_URL = 'http://www.msftconnecttest.com/connecttest.txt';
const String CHANNEL_ID = 'autowifi_channel';

// 日志管理
class LogManager extends ChangeNotifier {
  static final LogManager _instance = LogManager._internal();
  factory LogManager() => _instance;
  LogManager._internal();

  final List<String> _logs = [];
  static const int _maxLogs = 100;

  List<String> get logs => List.unmodifiable(_logs);

  // 替换原有的 print 函数
  void log(String message) {
    final timestamp = DateTime.now().toLocal().toString().substring(11, 19);
    final logMessage = '[$timestamp] $message';
    
    _logs.add(logMessage);
    
    if (_logs.length > _maxLogs) {
      _logs.removeAt(0);
    }
    
    notifyListeners(); 
    
    if (kDebugMode) {
      print(logMessage);
    }
  }
}

// 后台服务

@pragma('vm:entry-point')
Future<bool> _backgroundIsInternetOk() async {
  try {
    LogManager().log('后台认证 - 网络检测开始');
    final resp = await http.get(Uri.parse(TEST_URL), headers: {'Cache-Control': 'no-cache'}).timeout(const Duration(seconds: 5));
    final result = resp.statusCode == 200 && resp.body.trim() == 'Microsoft Connect Test';
    LogManager().log('后台认证 - 网络检测结果: $result (状态码: ${resp.statusCode})');
    return result;
  } catch (e) {
    LogManager().log('后台认证 - 网络检测异常: $e');
    return false;
  }
}

@pragma('vm:entry-point')
Future<bool> _backgroundLogin(String username, String password) async {
  LogManager().log('后台认证 - 尝试登录: $username');
  try {
    final loginUri = Uri.http(
      AUTH_HOST,
      AUTH_PATH,
      {
        'callback': 'dr1003',
        'DDDDD': username,
        'upass': password, // 警告：此处应为加密后的密码
        '0MKKey': '123456', 
        'R1': '0', 'R3': '0', 'R6': '0', 
        'para': '00', 'v6ip': '', 'v': '3196', 
      },
    );
    final response = await http.get(loginUri).timeout(const Duration(seconds: 8));
    
    final result = response.statusCode == 200 && 
           (response.body.contains('成功') || response.body.contains('"result":1'));
    
    LogManager().log('后台认证 - 登录响应: ${response.statusCode}, 结果: $result');
    return result;

  } catch (e) {
    LogManager().log('后台认证 - 登录异常: $e');
    return false;
  }
}

@pragma('vm:entry-point')
Future<void> backgroundTask(ServiceInstance service) async {
  LogManager().log('后台任务 - 步骤 1: 隔离区入口'); // LOG 1
  Timer? timer;

  try {
    LogManager().log('后台任务 - 步骤 2: 尝试获取 SharedPreferences 实例'); // LOG 2
    final prefs = await SharedPreferences.getInstance();
    LogManager().log('后台任务 - 步骤 3: SharedPreferences 实例获取成功'); // LOG 3

    service.on('stopService').listen((_) {
      LogManager().log('后台任务 - 收到停止服务指令，退出');
      timer?.cancel();
      service.stopSelf();
    });

    int normal = 0;
    int reconnect = 0;
    int fail = 0;

    LogManager().log('后台任务 - 步骤 4: 准备启动 Timer (5秒周期)'); // LOG 4
    // 保持 5 秒周期，以便在诊断阶段快速获取反馈
    timer = Timer.periodic(const Duration(seconds: 5), (_) async {
      LogManager().log('后台任务 - 步骤 5: Timer 循环开始执行'); // LOG 5 (关键)

      final username = prefs.getString('username') ?? '';
      final password = prefs.getString('password') ?? '';

      if (username.isEmpty || password.isEmpty) {
        LogManager().log('后台任务 - 步骤 6: 配置为空，中止循环。');
        service.invoke('updateCounters', {'status': '配置缺失'});
        return;
      }

      bool netOk = await _backgroundIsInternetOk();
      bool ok = false; 

      if (netOk) {
        normal++;
      } else {
        ok = await _backgroundLogin(username, password);
        if (ok) {
          reconnect++;
        } else {
          fail++;
        }
      }

      LogManager().log('后台任务 - 步骤 7: 发送状态到前台: NetOK=$netOk'); // LOG 7
      service.invoke('updateCounters', {
        'normal': normal,
        'reconnect': reconnect,
        'fail': fail,
        'status': netOk ? '网络正常' : (ok ? '重连成功' : '重连失败'),
      });
    });

  } catch (e, stack) {
    LogManager().log('后台任务发生致命错误: $e'); // LOG 8 (错误捕获)
    LogManager().log('堆栈追踪: $stack');
    service.invoke('updateCounters', {'status': '服务崩溃'});
    service.stopSelf();
  }
}

// 前端

Future<void> _initBackgroundService() async {
  final service = FlutterBackgroundService();

  if (Platform.isAndroid) {
    // 通知渠道配置
    final FlutterLocalNotificationsPlugin flutterLocalNotificationsPlugin = FlutterLocalNotificationsPlugin();
    const AndroidInitializationSettings initializationSettingsAndroid = AndroidInitializationSettings('@mipmap/ic_launcher');
    const InitializationSettings initializationSettings = InitializationSettings(android: initializationSettingsAndroid);
    await flutterLocalNotificationsPlugin.initialize(initializationSettings);

    const AndroidNotificationChannel channel = AndroidNotificationChannel(
      CHANNEL_ID, 'Auto WIFI Service', description: '用于保持校园网连接的后台服务', importance: Importance.low,
    );
    await flutterLocalNotificationsPlugin.resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>()?.createNotificationChannel(channel);
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

void main() {
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
    'normal': 0, 'reconnect': 0, 'fail': 0
  });

  @override
  void initState() {
    super.initState();
    _initPrefs();
    _listenBackgroundStatus(); 
  }

  // 初始化时加载配置
  Future<void> _initPrefs() async {
    prefs = await SharedPreferences.getInstance();
    username = prefs.getString('username') ?? '';
    password = prefs.getString('password') ?? '';
    configured = username.isNotEmpty; 
    setState(() {});
  }

  void _listenBackgroundStatus() async {
    final service = FlutterBackgroundService();

    if (await service.isRunning()) {
        setState(() => status = '后台已运行');
    }

    service.on('updateCounters').listen((data) {
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
    });
  }

  void _showLogDialog() {
    showDialog(
      context: context,
      builder: (BuildContext context) {
        return AlertDialog(
          title: const Text('运行时日志 (最新在上)'),
          content: SizedBox(
            width: double.maxFinite,
            height: 400, // 限制高度
            // 实时更新日志内容
            child: ValueListenableBuilder(
              valueListenable: LogManager(),
              builder: (context, _, __) {
                final logs = LogManager().logs.reversed.toList(); 
                return ListView.builder(
                  itemCount: logs.length,
                  reverse: true, // 保持滚动条在底部
                  itemBuilder: (context, index) {
                    String log = logs[index];
                    TextStyle style = const TextStyle(fontSize: 12, fontFamily: 'monospace');
                    if (log.contains('失败') || log.contains('错误') || log.contains('致命错误')) {
                      style = style.copyWith(fontWeight: FontWeight.bold, color: Colors.red);
                    }
                    
                    return Padding(
                      padding: const EdgeInsets.symmetric(vertical: 1),
                      child: Text(log, style: style),
                    );
                  },
                );
              },
            ),
          ),
          actions: <Widget>[
            TextButton(
              onPressed: () {
                Navigator.of(context).pop();
              },
              child: const Text('关闭'),
            ),
          ],
        );
      },
    );
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
                TextField(controller: userCtrl, decoration: const InputDecoration(labelText: '用户名')),
                TextField(controller: passCtrl, obscureText: true, decoration: const InputDecoration(labelText: '密码')),
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
    LogManager().log('前台操作 - 尝试启动服务...');
    if (!configured || username.isEmpty || password.isEmpty) {
      LogManager().log('前台操作 - 启动失败：未配置账号');
      setState(() => status = '启动失败：请先配置账号');
      return;
    } 

    final service = FlutterBackgroundService();

    if (await service.isRunning()) {
        LogManager().log('前台操作 - 服务已在运行，中止启动');
        setState(() => status = '任务已在运行');
        return;
    }

    if (Platform.isAndroid) {
        final started = await service.startService(); 
        
        setState(() {
             status = started ? '启动中...' : '启动失败：系统拒绝';
        });

        if (mounted) {
            final message = started ? '后台服务启动命令已发送。' : '启动失败：系统拒绝。';
            LogManager().log('前台操作 - $message');
            ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(content: Text(message)),
            );
        }
    }

    _countersNotifier.value = {'normal': 0, 'reconnect': 0, 'fail': 0};
  }

  Future<void> _stopService() async {
    LogManager().log('前台操作 - 尝试停止服务');
    final service = FlutterBackgroundService();
    if (await service.isRunning()) {
        service.invoke("stopService"); 
    }
    setState(() {
        status = '已停止';
    });
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
            if (configured)
              Text('当前账号: $username'),
            const SizedBox(height: 16),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                ElevatedButton(onPressed: _showConfigDialog, child: const Text('配置')),
                ElevatedButton(onPressed: !configured ? null : _startLoop, child: const Text('开始任务')),
                ElevatedButton(onPressed: _stopService, style: ElevatedButton.styleFrom(backgroundColor: Colors.red), child: const Text('停止')),
                ElevatedButton(onPressed: _showLogDialog, child: const Text('查看日志')),
              ],
            ),
            const SizedBox(height: 20),
            Text('运行状态: $status', style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
            const SizedBox(height: 10),
            ValueListenableBuilder<Map<String, dynamic>>(
              valueListenable: _countersNotifier,
              builder: (context, counters, child) {
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('网络正常: ${counters['normal']} 次', style: const TextStyle(fontSize: 14)),
                    Text('重连成功: ${counters['reconnect']} 次', style: const TextStyle(fontSize: 14)),
                    Text('重连失败: ${counters['fail']} 次', style: const TextStyle(fontSize: 14)),
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
