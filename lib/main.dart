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

const String TEST_URL = 'http://www.msftconnecttest.com/connecttest.txt';
//const String TEST_URL = 'http://192.168.31.113:50000/local_connect_test';
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

String getLatestLog() {
if (_logs.isEmpty) return '';
return _logs.last;
}

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

Future<bool> _backgroundLogin(String username, String password) async {
logManager.log('后台认证 - 尝试登录: $username');
try {
// 手动构造 URL
String url =
'http://192.168.110.100/drcom/login?callback=dr1003&DDDDD=$username&upass=$password&0MKKey=123456&R1=0&R3=0&R6=0&para=00&v6ip=&v=3196';
//String url =
//    'http://192.168.31.113:50000/drcom/login?callback=dr1003&DDDDD=$username&upass=$password&0MKKey=123456&R1=0&R3=0&R6=0&para=00&v6ip=&v=3196';
final loginUri = Uri.parse(url);
logManager.logDebug('后台认证 - 请求 URL: $loginUri');

final response = await http
.get(
loginUri,
headers: {
'User-Agent': 'curl/7.88.1', // 模拟 curl
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
.timeout(const Duration(seconds: 3));
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
// 确保第一时间初始化日志
logManager.log('后台任务 - 启动');

Timer? timer;
int consecutiveErrors = 0;
const maxConsecutiveErrors = 3;

try {
logManager.logDebug('后台任务 - 获取 SharedPreferences 实例');
final prefs = await SharedPreferences.getInstance();
logManager.logDebug('后台任务 - SharedPreferences 实例获取成功');

// 确保服务监听器设置在最前面
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

logManager.log('后台任务 - 启动定时检测 (5秒周期)');
timer = Timer.periodic(const Duration(seconds: 5), (_) async {
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

logManager.logDebug('后台任务 - 发送状态更新');
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

// 前端

Future<void> _initBackgroundService() async {
final service = FlutterBackgroundService();

// 首先配置Android特定设置
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

// 对于Android，额外处理通知渠道
if (Platform.isAndroid) {
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
importance: Importance.high,
playSound: false,
enableVibration: false,
);

await flutterLocalNotificationsPlugin
.resolvePlatformSpecificImplementation<
AndroidFlutterLocalNotificationsPlugin
>()
?.createNotificationChannel(channel);
}
}

Future<void> main() async {
WidgetsFlutterBinding.ensureInitialized();
await _initBackgroundService();
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

void openBatteryOptimizationSettings() { try { // 尝试打开系统电池优化设置 final intent = AndroidIntent( action: 'android.settings.IGNORE_BATTERY_OPTIMIZATION_SETTINGS', ); intent.launch(); } catch (e) { // 如果失败，提示用户手动操作 showDialog( context: context, builder: (ctx) => AlertDialog( title: Text('请手动关闭电池优化'), content: Text( '为确保后台服务正常运行，请前往：\n' '设置 → 电池 → 电池优化 → 找到本应用 → 选择“不优化”', ), actions: [ TextButton( onPressed: Navigator.of(ctx).pop, child: Text('我知道了'), ) ], ), ); } }

Future<void> _requestNotificationPermission() async {
if (Platform.isAndroid) {
// 检查并请求通知权限 （Android 13+)
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
}

void _checkServiceStatus() async {
try {
final service = FlutterBackgroundService();
// 检查服务是否已在运行
bool isRunning = await service.isRunning();

if (isRunning) {
// 正在运行，只更新状态
setState(() => status = '后台已运行');
} else {
logManager.log('前台操作 - 检测到服务未运行，尝试自动启动...');

// 检查配置，避免无配置启动
final prefs = await SharedPreferences.getInstance();
final username = prefs.getString('username') ?? '';
final password = prefs.getString('password') ?? '';

if (username.isNotEmpty && password.isNotEmpty) {
// 如果配置存在，启动服务
await _startLoop(); // 这会启动服务
// 等待一小段时间后检查状态
await Future.delayed(const Duration(milliseconds: 500));
bool nowRunning = await service.isRunning();
setState(() => status = nowRunning ? '后台已运行' : '启动失败');
} else {
// 如果配置缺失，给出提示
setState(() => status = '配置缺失，请先设置账号');
logManager.logWarning('前台操作 - 配置缺失，无法自动启动服务。');
}
}
} catch (e) {
logManager.logError('检查或自动启动服务失败: $e');
setState(() => status = '服务检查失败');
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

final latestLog = data['latestLog'] as String?;
if (latestLog != null && latestLog.isNotEmpty) {
// 检查前台 LogManager 中是否已有这条日志（防止重复）
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
_forceStopAllServices();
Navigator.pop(ctx);
},
child: const Text('保存'),
),
],
),
);
}

Future<void> _startLoop() async {
logManager.log('前台操作 - 尝试启动服务...');
if (!configured || username.isEmpty || password.isEmpty) {
logManager.logWarning('前台操作 - 启动失败：未配置账号');
setState(() => status = '启动失败：请先配置账号');
return;
}

try {
final service = FlutterBackgroundService();

// 不再检查是否运行，直接尝试启动服务
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

Future<void> _forceStopAllServices() async {
logManager.log('前台操作 - 强制停止所有服务');

try {
final service = FlutterBackgroundService();

try {
if (await service.isRunning()) {
service.invoke("stopService");
}
} catch (e) {
logManager.logWarning('发送停止指令失败: $e');
}

try {
if (await service.isRunning()) {
service.invoke('stopService');
await Future.delayed(const Duration(milliseconds: 300)); // 等待后台处理完
}
} catch (e) {
logManager.logWarning('调用停止服务失败: $e');
}

try {
if (Platform.isAndroid) {
final FlutterLocalNotificationsPlugin
flutterLocalNotificationsPlugin = FlutterLocalNotificationsPlugin();
await flutterLocalNotificationsPlugin.cancelAll();
}
} catch (e) {
logManager.logWarning('清除通知失败: $e');
}

// 更新状态
setState(() {
status = '已强制停止';
});

logManager.log('前台操作 - 所有服务已强制停止');

if (mounted) {
ScaffoldMessenger.of(
context,
).showSnackBar(const SnackBar(content: Text('已强制停止所有服务')));
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

Future<void> _immediateLogin() async {
logManager.log('前台操作 - 立即登录');

try {
final prefs = await SharedPreferences.getInstance();
final username = prefs.getString('username') ?? '';
final password = prefs.getString('password') ?? '';

if (username.isEmpty || password.isEmpty) {
logManager.logWarning('前台操作 - 登录失败：未配置账号');
if (mounted) {
ScaffoldMessenger.of(
context,
).showSnackBar(const SnackBar(content: Text('请先配置账号和密码')));
}
return;
}

// 显示正在登录的提示
if (mounted) {
ScaffoldMessenger.of(
context,
).showSnackBar(const SnackBar(content: Text('正在登录...')));
}

// 调用登录函数
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
appBar: AppBar(title: const Text('Auto-WIFI (beta)')),
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
onPressed: _forceStopAllServices, // 新添加的强制停止按钮
style: ElevatedButton.styleFrom(
backgroundColor: Colors.orange,
),
child: const Text('停止APP'),
),
ElevatedButton(
onPressed: _exportLogs,
child: const Text('导出日志'),
),
ElevatedButton(
onPressed: !configured ? null : _immediateLogin,
child: const Text('立即登录'),
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