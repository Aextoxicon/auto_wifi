import 'dart:async';
import 'dart:developer';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:http/http.dart' as http;
import 'package:flutter_background_service/flutter_background_service.dart';

// 前台任务
Future<void> backgroundTask(ServiceInstance service) async {
  // 使用 Timer.periodic 并保存 timer 引用以便后续取消
  Timer? timer;
  timer = Timer.periodic(Duration(seconds: 3), (_) async {
    final prefs = await SharedPreferences.getInstance();
    final username = prefs.getString('username') ?? '';
    final password = prefs.getString('password') ?? '';
    if (username.isEmpty || password.isEmpty) return;

    bool netOk = await _isInternetOk();
    int normal = prefs.getInt('normal_count') ?? 0;
    int reconnect = prefs.getInt('reconnect_count') ?? 0;
    int fail = prefs.getInt('fail_count') ?? 0;

    if (netOk) {
      normal++;
    } else {
      bool ok = await _login(username, password);
      if (ok) {
        reconnect++;
      } else {
        fail++;
      }
    }

    await _saveCounters(normal, reconnect, fail);
  });

  // 监听服务销毁事件
  service.on('stopService').listen((event) {
    timer?.cancel();
    timer = null;
    service.stopSelf();
  });
}

@override
Future<void> onExit(DateTime timestamp) async {}

@override
Future<bool> _isInternetOk() async {
  try {
    final resp = await http.get(
      Uri.parse('http://www.msftconnecttest.com/connecttest.txt'),
      headers: {'Cache-Control': 'no-cache'},
    );
    // 必须同时满足：状态码 200 + 响应体为 "Microsoft Connect Test"
    return resp.statusCode == 200 &&
        resp.body.trim() == 'Microsoft Connect Test';
  } catch (e) {
    return false;
  }
}

Future<bool> _login(String username, String password) async {
  try {
    String url =
        'http://192.168.110.100/drcom/login?callback=dr1003&DDDDD=${Uri.encodeComponent(username)}&upass=${Uri.encodeComponent(password)}&0MKKey=123456&R1=0&R3=0&R6=0&para=00&v6ip=&v=3196';
    final resp = await http.get(Uri.parse(url));
    if (resp.statusCode == 200) {
      // 检查响应体是否包含 result:1
      return resp.body.contains('"result":1');
    }
    return false;
  } catch (e) {
    return false;
  }
}

Future<void> _saveCounters(int normal, int reconnect, int fail) async {
  final prefs = await SharedPreferences.getInstance();
  await prefs.setInt('normal_count', normal);
  await prefs.setInt('reconnect_count', reconnect);
  await prefs.setInt('fail_count', fail);
}

// 服务初始化
Future<void> _initBackgroundService() async {
  final service = FlutterBackgroundService();

  if (Platform.isAndroid) {
    await service.configure(
      androidConfiguration: AndroidConfiguration(
        onStart: backgroundTask,
        autoStart: false,
        isForegroundMode: true,
        notificationChannelId: 'autowifi_channel',
        initialNotificationTitle: 'Auto-WIFI',
        initialNotificationContent: '保持校园网连接',
        foregroundServiceTypes: [AndroidForegroundType.location],
      ),
      iosConfiguration: IosConfiguration(),
    );
  }
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

  void _startLoop() async {
    if (!configured) return;

    final service = FlutterBackgroundService();
    if (Platform.isAndroid) {
      await service.startService();
    }

    // 启动 UI 定时器的代码保持不变
    _uiTimer?.cancel();
    _uiTimer = Timer.periodic(const Duration(seconds: 1), (_) async {
      final normal = prefs.getInt('normal_count') ?? 0;
      final reconnect = prefs.getInt('reconnect_count') ?? 0;
      final fail = prefs.getInt('fail_count') ?? 0;

      String newStatus;
      if (normal > 0) {
        newStatus = '网络正常（$normal 次）';
      } else if (reconnect > 0) {
        newStatus = '重连成功（$reconnect 次）';
      } else if (fail > 0) {
        newStatus = '重连失败（$fail 次）';
      } else {
        newStatus = '前台任务运行中...';
      }

      if (newStatus != status) {
        setState(() => status = newStatus);
      }
    });
  }

  @override
  void dispose() {
    _uiTimer?.cancel();
    _uiTimer = null;
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
                  child: const Text('开始自动认证'),
                ),
                ElevatedButton(
                  onPressed: () async {
                    final service = FlutterBackgroundService();
                    if (Platform.isAndroid) {
                      service.invoke("stopService");
                    }
                    _uiTimer?.cancel();
                    _uiTimer = null;
                    setState(() => status = '已停止');
                  },
                  style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
                  child: const Text('停止'),
                ),
              ],
            ),
            const SizedBox(height: 20),
            Text('状态: $status', style: const TextStyle(fontSize: 16)),
          ],
        ),
      ),
    );
  }
}
