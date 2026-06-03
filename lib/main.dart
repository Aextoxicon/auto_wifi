import 'dart:async';
import 'dart:io';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:http/http.dart' as http;
import 'dart:developer' as developer;
import 'package:package_info_plus/package_info_plus.dart';
import 'package:url_launcher/url_launcher.dart';

const String TEST_URL = 'http://www.msftconnecttest.com/connecttest.txt';
final logManager = LogManager._internal();

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const MyApp());
}

class LogManager extends ChangeNotifier {
  static LogManager? _instance;
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

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Eureka-gjjgxx',
      theme: ThemeData(primarySwatch: Colors.blue),
      home: const DrcomAuthPC(),
    );
  }
}

class DrcomAuthPC extends StatefulWidget {
  const DrcomAuthPC({super.key});

  @override
  State<DrcomAuthPC> createState() => _DrcomAuthPCState();
}

class _DrcomAuthPCState extends State<DrcomAuthPC> {
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

  Future<void> _initPrefs() async {
    try {
      prefs = await SharedPreferences.getInstance();
      username = prefs.getString('username') ?? '';
      password = prefs.getString('password') ?? '';
      configured = username.isNotEmpty;
      setState(() {});
    } catch (e) {
      print('初始化配置失败: $e');
    }
  }

  @override
  void initState() {
    super.initState();
    _initPrefs();
    _startPCLoop();
  }

  Future<void> _startPCLoop() async {
    if (!configured || username.isEmpty || password.isEmpty) {
      setState(() => status = '请先配置账号');
      return;
    }
    _runPCTask();
  }

  void _runPCTask() {
    Timer.periodic(const Duration(seconds: 1), (timer) async {
      if (!mounted) {
        timer.cancel();
        return;
      }

      final username = prefs.getString('username') ?? '';
      final password = prefs.getString('password') ?? '';

      if (username.isEmpty || password.isEmpty) {
        setState(() => status = '配置缺失');
        return;
      }

      try {
        bool netOk = await _pcIsInternetOk();
        if (netOk) {
          _updateCounters('normal');
          setState(() => status = '网络正常');
        } else {
          bool loginResult = await _pcLogin(username, password);
          if (loginResult) {
            _updateCounters('reconnect');
            setState(() => status = '重连成功');
          } else {
            _updateCounters('fail');
            setState(() => status = '重连失败');
          }
        }
      } catch (e) {
        setState(() => status = '任务错误: $e');
      }
    });
  }

  Future<bool> _pcLogin(String username, String password) async {
    try {
      String url =
          'http://192.168.110.100/drcom/login?callback=dr1003&DDDDD=$username&upass=$password&0MKKey=123456&R1=0&R3=0&R6=0&para=00&v6ip=&v=3196';
      final loginUri = Uri.parse(url);
      final response = await http
          .get(
            loginUri,
            headers: {
              'User-Agent': 'curl/7.88.1',
              'Accept': '*/*',
              'Connection': 'close',
            },
          )
          .timeout(const Duration(seconds: 2));

      final result =
          response.statusCode == 200 &&
          (response.body.contains('"result":1') ||
              response.body.contains('dr1003({"result":1}'));
      return result;
    } catch (e) {
      print('登录异常: $e');
      return false;
    }
  }

  Future<bool> _pcIsInternetOk() async {
    try {
      final resp = await http
          .get(Uri.parse(TEST_URL), headers: {'Cache-Control': 'no-cache'})
          .timeout(const Duration(seconds: 1));
      final result =
          resp.statusCode == 200 &&
          resp.body.trim() == 'Microsoft Connect Test';
      return result;
    } catch (e) {
      final prefs = await SharedPreferences.getInstance();
      String username = prefs.getString('username') ?? '';
      String password = prefs.getString('password') ?? '';
      await _pcLogin(username, password);
      return false;
    }
  }

  void _updateCounters(String type) {
    final current = _countersNotifier.value;
    _countersNotifier.value = {
      'normal': type == 'normal' ? current['normal']! + 1 : current['normal'],
      'reconnect': type == 'reconnect'
          ? current['reconnect']! + 1
          : current['reconnect'],
      'fail': type == 'fail' ? current['fail']! + 1 : current['fail'],
    };
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
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('取消'),
          ),
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
              Navigator.of(ctx).pop();
              _startPCLoop();
            },
            child: const Text('保存'),
          ),
        ],
      ),
    );
  }

  Future<void> _fetchAndCompareVersion() async {
    const githubApiUrl =
        'https://api.github.com/repos/Aextoxicon/eureka/releases/latest';

    try {
      logManager.log('版本检查 - 开始抓取远程版本信息');

      PackageInfo packageInfo = await PackageInfo.fromPlatform();
      String localVersion = packageInfo.version;

      logManager.log('版本检查 - 本地版本: $localVersion');

      final response = await http
          .get(
            Uri.parse(githubApiUrl),
            headers: {
              'User-Agent': 'Eureka-gjjgxx-app',
            },
          )
          .timeout(const Duration(seconds: 10));

      if (response.statusCode == 200) {
        final jsonResponse = json.decode(response.body);
        final remoteVersion = jsonResponse['tag_name'].toString().replaceAll(
          RegExp(r'^v'),
          '',
        );

        logManager.log(
          '版本检查 - 远程版本: $remoteVersion, 本地版本: $localVersion',
        );

        final remote = Version.parse(remoteVersion);
        final local = Version.parse(localVersion);

        if (remote <= local) {
          logManager.log('版本检查 - 当前已是最新版本');
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(const SnackBar(content: Text('当前已是最新版本')));
        } else {
          logManager.log('版本检查 - 有新版本可用: $remoteVersion');
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                '发现新版本 $remoteVersion，请访问 https://github.com/aextoxicon/Eureka-gjjgxx/releases获取更新',
              ),
            ),
          );
        }
      }
    } catch (e, stack) {
      logManager.logError('版本检查 - 抓取远程版本异常: $e', stack);
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('检查更新失败：$e')));
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
      bool result = await _pcLogin(username, password);
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
      appBar: AppBar(title: const Text('Eureka-gjjgxx PC')),
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
                SizedBox(
                  width: MediaQuery.of(context).size.width * 0.6,
                  child: ElevatedButton(
                    onPressed: _showConfigDialog,
                    child: const Text('配置'),
                  ),
                ),
                const SizedBox(height: 8),
                SizedBox(
                  width: MediaQuery.of(context).size.width * 0.6,
                  child: ElevatedButton(
                    onPressed: !configured
                        ? null
                        : () {
                            _startPCLoop();
                          },
                    child: const Text('开始任务'),
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
                const SizedBox(height: 8),
                SizedBox(
                  width: MediaQuery.of(context).size.width * 0.6,
                  child: ElevatedButton(
                    onPressed: () {
                      _fetchAndCompareVersion();
                    },
                    child: const Text('检查更新'),
                  ),
                ),
                const SizedBox(height: 8),
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
                      '正常次数: ${counters['normal']} 次',
                      style: const TextStyle(fontSize: 14),
                    ),
                    Text(
                      '重连次数: ${counters['reconnect']} 次',
                      style: const TextStyle(fontSize: 14),
                    ),
                    Text(
                      '失败次数: ${counters['fail']} 次',
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
