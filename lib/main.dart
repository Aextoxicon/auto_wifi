import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:shared_preferences/shared_preferences.dart'; // 仅用于配置存储
import 'package:http/http.dart' as http;
import 'package:flutter_background_service/flutter_background_service.dart';

// 全局常量
const String AUTH_HOST = '192.168.110.100';
const String AUTH_PATH = '/drcom/login';
const String TEST_URL = 'http://www.msftconnecttest.com/connecttest.txt';
const String CHANNEL_ID = 'autowifi_channel';

@pragma('vm:entry-point')
Future<bool> _backgroundIsInternetOk() async {
  try {
    // 简化：只检查状态码和期望内容是否一致
    final resp = await http.get(Uri.parse(TEST_URL), headers: {'Cache-Control': 'no-cache'}).timeout(const Duration(seconds: 5));
    return resp.statusCode == 200 && resp.body.trim() == 'Microsoft Connect Test';
  } catch (_) {
    return false;
  }
}

@pragma('vm:entry-point')
Future<bool> _backgroundLogin(String username, String password) async {
  try {
    final loginUri = Uri.http(
      AUTH_HOST,
      AUTH_PATH,
      {
        'callback': 'dr1003',
        'DDDDD': username,
        'upass': password,
        '0MKKey': '123456', 
        'R1': '0', 'R3': '0', 'R6': '0', 
        'para': '00', 'v6ip': '', 'v': '3196', 
      },
    );
    final response = await http.get(loginUri).timeout(const Duration(seconds: 8));
    return response.statusCode == 200 && 
           (response.body.contains('成功') || response.body.contains('"result":1'));

  } catch (_) {
    return false;
  }
}

@pragma('vm:entry-point')
Future<void> backgroundTask(ServiceInstance service) async {
  print('后台任务已启动');
  Timer? timer;
  
  // 只在启动时加载一次持久化配置
  final prefs = await SharedPreferences.getInstance();
  
  service.on('stopService').listen((_) {
    print('收到停止服务指令');
    timer?.cancel();
    service.stopSelf();
  });

  int normal = 0;
  int reconnect = 0;
  int fail = 0;

  timer = Timer.periodic(const Duration(seconds: 5), (_) async {
    print('执行后台任务循环...');
    
    final username = prefs.getString('username') ?? '';
    final password = prefs.getString('password') ?? '';

    if (username.isEmpty || password.isEmpty) {
      print('配置为空，中止循环。');
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

    // 发送计数器状态到前台
    service.invoke('updateCounters', {
      'normal': normal,
      'reconnect': reconnect,
      'fail': fail,
      'status': netOk ? '网络正常' : (ok ? '重连成功' : '重连失败'),
    });
  });
}

// UI
Future<void> _initBackgroundService() async {
  final service = FlutterBackgroundService();

  if (Platform.isAndroid) {
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
    configured = username.isNotEmpty; // 只要有用户名就视为配置
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
              
              // **>> 仅存储配置：只将账号密码写入 SharedPreferences <<**
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
    // 检查配置是否已加载到 UI 状态
    if (!configured || username.isEmpty || password.isEmpty) {
      setState(() => status = '启动失败：请先配置账号');
      return;
    } 
    
    final service = FlutterBackgroundService();
    
    if (await service.isRunning()) {
        setState(() => status = '任务已在运行');
        return;
    }

    if (Platform.isAndroid) {
        // 服务启动时，后台会自己去加载 SharedPreferences
        final started = await service.startService(); 
        
        setState(() {
             status = started ? '启动中...' : '启动失败：系统拒绝';
        });

        if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                    content: Text(started ? '后台服务启动命令已发送。' : '启动失败：系统拒绝。'),
                ),
            );
        }
    }

    _countersNotifier.value = {'normal': 0, 'reconnect': 0, 'fail': 0};
  }

  Future<void> _stopService() async {
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
    // 略过 _showConfigDialog，保持与原代码结构一致
    return Scaffold(
      appBar: AppBar(title: const Text('Auto-WIFI')),
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
              children: [
                ElevatedButton(onPressed: _showConfigDialog, child: const Text('配置')),
                ElevatedButton(onPressed: !configured ? null : _startLoop, child: const Text('开始任务')),
                ElevatedButton(onPressed: _stopService, style: ElevatedButton.styleFrom(backgroundColor: Colors.red), child: const Text('停止')),
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
