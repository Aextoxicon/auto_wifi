import 'dart:async';
import 'dart:developer';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:http/http.dart' as http;
import 'package:flutter_background_service/flutter_background_service.dart';

// 前台任务
@pragma('vm:entry-point')
Future<void> backgroundTask(ServiceInstance service) async {
  print('后台任务已启动');
  Timer? timer;
  service.on('stopService').listen((_) {
    print('收到停止服务指令');
    timer?.cancel();
    service.stopSelf();
  });

  int normal = 0;
  int reconnect = 0;
  int fail = 0;

  timer = Timer.periodic(Duration(seconds: 3), (_) async {
    print('执行后台任务循环...');
    try {
      final prefs = await SharedPreferences.getInstance();
      final username = prefs.getString('username') ?? '';
      final password = prefs.getString('password') ?? '';
      if (username.isEmpty || password.isEmpty) {
        print('用户名或密码为空，跳过本次循环');
        return;
      }

      // 使用后台任务专用的网络检测函数
      bool netOk = await _backgroundIsInternetOk();
      print('网络检测结果: $netOk');

      if (netOk) {
        normal++;
        print('网络正常，计数器+1: ${normal}');
      } else {
        // 使用后台任务专用的登录函数
        bool ok = await _backgroundLogin(username, password);
        print('登录结果: $ok');
        if (ok) {
          reconnect++;
          print('重连成功，计数器+1: ${reconnect}');
        } else {
          fail++;
          print('重连失败，计数器+1: ${fail}');
        }
      }

      // 发送计数器状态到前台
      service.invoke('updateCounters', {
        'normal': normal,
        'reconnect': reconnect,
        'fail': fail,
      });

      print(
        '计数器状态 - 正常:$normal 重连:$reconnect 失败:$fail',
      );
    } catch (e) {
      print('Background task error: $e');
    }
  });
}

// 为后台任务专门实现的网络检测函数
@pragma('vm:entry-point')
Future<bool> _backgroundIsInternetOk() async {
  try {
    print('开始网络检测...');
    final client = http.Client();
    final resp = await client.get(
      Uri.parse('http://www.msftconnecttest.com/connecttest.txt'),
      headers: {'Cache-Control': 'no-cache'},
    );
    client.close();

    print('网络检测响应 - 状态码: ${resp.statusCode}');
    print('网络检测响应 - 内容: "${resp.body}"');
    print('期望内容: "Microsoft Connect Test"');
    print(
      '实际内容匹配: "${resp.body.trim()}" == "Microsoft Connect Test" is ${resp.body.trim() == 'Microsoft Connect Test'}',
    );

    bool result =
        resp.statusCode == 200 && resp.body.trim() == 'Microsoft Connect Test';
    print('网络检测最终结果: $result');
    return result;
  } catch (e) {
    print('网络检测异常: $e');
    return false;
  }
}

// 为后台任务专门实现的登录函数
@pragma('vm:entry-point')
Future<bool> _backgroundLogin(String username, String password) async {
  try {
    print('开始登录... 用户名: $username');
    
    final loginUri = Uri.http(
      '192.168.110.100',
      '/drcom/login',
      {
        'callback': 'dr1003',
        'DDDDD': username,
        'upass': password,
        '0MKKey': '123456',   // 固定参数
        'R1': '0',            // 固定参数
        'R3': '0',            // 固定参数
        'R6': '0',            // 固定参数
        'para': '00',         // 固定参数
        'v6ip': '',           // 固定参数
        'v': '3196',          // 固定参数
      },
    );

    print('构造的登录URI: $loginUri');

    final client = http.Client();
    final response = await client
        .get(loginUri)
        .timeout(const Duration(seconds: 8));
    client.close();

    print('登录响应 - 状态码: ${response.statusCode}');
    bool result = response.statusCode == 200 && 
                  response.body.contains('成功') || response.body.contains('"result":1'); 

    print('登录结果: $result');
    return result;

  } catch (e) {
    print('登录异常: $e');
    return false;
  }
}


@override
Future<void> onExit(DateTime timestamp) async {}

Future<bool> _isInternetOk() async {
  try {
    print('开始网络检测...');
    final resp = await http.get(
      Uri.parse('http://www.msftconnecttest.com/connecttest.txt'),
      headers: {'Cache-Control': 'no-cache'},
    );
    print('网络检测响应 - 状态码: ${resp.statusCode}');
    print('网络检测响应 - 内容: "${resp.body}"');
    print('期望内容: "Microsoft Connect Test"');
    print(
      '实际内容匹配: "${resp.body.trim()}" == "Microsoft Connect Test" is ${resp.body.trim() == 'Microsoft Connect Test'}',
    );

    bool result =
        resp.statusCode == 200 && resp.body.trim() == 'Microsoft Connect Test';
    print('网络检测最终结果: $result');
    return result;
  } catch (e) {
    print('网络检测异常: $e');
    return false;
  }
}

Future<bool> _login(String username, String password) async {
  try {
    final client = http.Client();
    final response = await client
        .get(Uri.parse('http://192.168.110.100/...'))
        .timeout(const Duration(seconds: 8));
    client.close();
    return response.statusCode == 200 && response.body.contains('"result":1');
  } catch (e) {
    return false;
  }
}

// 服务初始化
Future<void> _initBackgroundService() async {
  final service = FlutterBackgroundService();

  // 配置 Android 通知渠道
  if (Platform.isAndroid) {
    final FlutterLocalNotificationsPlugin flutterLocalNotificationsPlugin =
        FlutterLocalNotificationsPlugin();

    const AndroidInitializationSettings initializationSettingsAndroid =
        AndroidInitializationSettings('@mipmap/ic_launcher');

    const InitializationSettings initializationSettings =
        InitializationSettings(android: initializationSettingsAndroid);

    await flutterLocalNotificationsPlugin.initialize(initializationSettings);

    // 创建通知渠道 (Android 8.0+)
    const AndroidNotificationChannel channel = AndroidNotificationChannel(
      'autowifi_channel', // id
      'Auto WIFI Service', // title
      description: '用于保持校园网连接的后台服务', // description
      importance: Importance.low,
    );

    await flutterLocalNotificationsPlugin
        .resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin
        >()
        ?.createNotificationChannel(channel);
  }

  // 正确配置服务
  await service.configure(
    androidConfiguration: AndroidConfiguration(
      onStart: backgroundTask,
      autoStart: false,
      isForegroundMode: true,
      notificationChannelId: 'autowifi_channel',
      initialNotificationTitle: 'Auto-WIFI',
      initialNotificationContent: '保持校园网连接',
      foregroundServiceTypes: [AndroidForegroundType.dataSync],
    ),
    iosConfiguration: IosConfiguration(),
  );
}

// 主程序
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
  bool isWin = true;
  Timer? _uiTimer;
  String status = '准备就绪';

  @override
  void initState() {
    super.initState();
    _initPrefs();
  }

  Future<void> _initPrefs() async {
    prefs = await SharedPreferences.getInstance();
    configured = prefs.containsKey('username');
    if (configured) {
      username = prefs.getString('username') ?? '';
      password = prefs.getString('password') ?? '';
      isWin = prefs.getBool('is_win') ?? true;
    }
    setState(() {});
  }

  void _showConfigDialog() {
    final userCtrl = TextEditingController(text: username);
    final passCtrl = TextEditingController(text: password);
    bool dialogIsWin = isWin;

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('配置账号'),
        content: StatefulBuilder(
          builder: (BuildContext context, StateSetter setDialogState) {
            return Column(
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
                Row(
                  children: [
                    const Text('系统类型: '),
                    Checkbox(
                      value: dialogIsWin,
                      onChanged: (v) {
                        setDialogState(() {
                          dialogIsWin = v ?? true;
                        });
                      },
                    ),
                    const Text('Windows'),
                  ],
                ),
              ],
            );
          },
        ),
        actions: [
          TextButton(onPressed: Navigator.of(ctx).pop, child: const Text('取消')),
          ElevatedButton(
            onPressed: () {
              final u = userCtrl.text.trim();
              final p = passCtrl.text.trim();
              if (u.isEmpty || p.isEmpty) return;
              prefs.setString('username', u);
              prefs.setString('password', p);
              prefs.setBool('is_win', dialogIsWin); // 保存最终状态
              setState(() {
                username = u;
                password = p;
                isWin = dialogIsWin;
                configured = true;
              });
              Navigator.pop(ctx);
            },
            child: const Text('保存'),
          ),
        ],
      ),
    );
  }

  final ValueNotifier<Map<String, int>> _countersNotifier = ValueNotifier({
    'normal': 0,
    'reconnect': 0,
    'fail': 0,
  });

  void _startLoop() async {
    print('检查配置状态: configured=$configured');
    if (!configured) {
      print('未配置账号，无法启动服务');
      return;
    }
    print('账号信息 - 用户名: $username, 密码: ${password.isNotEmpty ? "已设置" : "未设置"}');

    final service = FlutterBackgroundService();

    // 监听后台计数器更新
    service.on('updateCounters').listen((data) {
      if (data != null && data is Map) {
        _countersNotifier.value = {
          'normal': data['normal'] as int? ?? 0,
          'reconnect': data['reconnect'] as int? ?? 0,
          'fail': data['fail'] as int? ?? 0,
        };

        // 更新状态显示
        String newStatus;
        if ((data['normal'] as int? ?? 0) > 0) {
          newStatus = '网络正常（${data['normal']} 次）';
        } else if ((data['reconnect'] as int? ?? 0) > 0) {
          newStatus = '重连成功（${data['reconnect']} 次）';
        } else if ((data['fail'] as int? ?? 0) > 0) {
          newStatus = '重连失败（${data['fail']} 次）';
        } else {
          newStatus = '前台任务运行中...';
        }

        if (newStatus != status) {
          setState(() => status = newStatus);
        }
      }
    });

    if (Platform.isAndroid) {
      print('尝试启动后台服务...');
      await service.startService();
      print('后台服务启动命令已发送');
    }

    // 重置本地计数器显示
    _countersNotifier.value = {'normal': 0, 'reconnect': 0, 'fail': 0};
  }

  // 改进停止方法
  Future<void> _stopService() async {
    final service = FlutterBackgroundService();
    if (Platform.isAndroid) {
      service.invoke("stopService");
    }
    _uiTimer?.cancel();
    _uiTimer = null;
    setState(() => status = '已停止');
  }

  @override
  void dispose() {
    _uiTimer?.cancel();
    _uiTimer = null;
    _countersNotifier.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
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
              Text('账号: $username | ${isWin ? 'Windows' : 'Linux/Android'}'),
            const SizedBox(height: 16),
            Wrap(
              spacing: 8,
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
                  onPressed: () async {
                    print('手动测试网络检测...');
                    bool result = await _isInternetOk();
                    print('手动测试结果: $result');

                    // 同时检查账号状态
                    final prefs = await SharedPreferences.getInstance();
                    final username = prefs.getString('username') ?? '';
                    final password = prefs.getString('password') ?? '';
                    print(
                      '当前保存的账号 - 用户名: $username, 密码: ${password.isNotEmpty ? "已设置" : "未设置"}',
                    );
                  },
                  child: const Text('测试网络'),
                ),
                ElevatedButton(
                  onPressed: _stopService,
                  style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
                  child: const Text('停止'),
                ),
              ],
            ),
            const SizedBox(height: 20),

            // 修改这部分来更好地显示计数器状态
            Text(
              '运行状态: $status',
              style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 10),

            // 单独显示计数器
            ValueListenableBuilder<Map<String, int>>(
              valueListenable: _countersNotifier,
              builder: (context, counters, child) {
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '网络正常: ${counters['normal']} 次', // 使用 counters 而不是 CounterManager()
                      style: const TextStyle(fontSize: 14),
                    ),
                    Text(
                      '重连成功: ${counters['reconnect']} 次', // 使用 counters 而不是 CounterManager()
                      style: const TextStyle(fontSize: 14),
                    ),
                    Text(
                      '重连失败: ${counters['fail']} 次', // 使用 counters 而不是 CounterManager()
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
