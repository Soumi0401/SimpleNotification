import 'package:flutter/material.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:timezone/data/latest.dart' as tz;
import 'package:timezone/timezone.dart' as tz;
import 'package:flutter_native_timezone/flutter_native_timezone.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:permission_handler/permission_handler.dart';
import 'dart:convert';
import 'package:flutter/services.dart';

class AlarmPermission {
  static const platform = MethodChannel('com.example.simplenotification/alarm');

  static Future<bool> areExactAlarmsAllowed() async {
    try {
      final allowed =
          await platform.invokeMethod<bool>('areExactAlarmsAllowed');
      return allowed ?? false;
    } catch (e) {
      return false;
    }
  }

  static Future<void> scheduleExactAlarm(
      int id, DateTime dateTime, String title, String text) async {
    try {
      await platform.invokeMethod('scheduleExactAlarm', {
        'id': id,
        'timeMillis': dateTime.millisecondsSinceEpoch,
        'title': title,
        'text': text,
      });
    } catch (e) {
      print('Failed to schedule exact alarm: $e');
    }
  }
}

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  tz.initializeTimeZones();
  final String timeZoneName = await FlutterNativeTimezone.getLocalTimezone();
  tz.setLocalLocation(tz.getLocation(timeZoneName));
  debugPrint('Local timezone set to: $timeZoneName');

  runApp(const SimpleNotificationApp());
}

class SimpleNotificationApp extends StatelessWidget {
  const SimpleNotificationApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'SimpleNotification',
      theme: ThemeData(primarySwatch: Colors.green),
      home: const TaskListPage(),
    );
  }
}

class Task {
  String name;
  TimeOfDay time;

  Task({required this.name, required this.time});

  Map<String, dynamic> toJson() => {
        'name': name,
        'hour': time.hour,
        'minute': time.minute,
      };

  static Task fromJson(Map<String, dynamic> json) => Task(
        name: json['name'],
        time: TimeOfDay(hour: json['hour'], minute: json['minute']),
      );
}

class TaskListPage extends StatefulWidget {
  const TaskListPage({super.key});

  @override
  State<TaskListPage> createState() => _TaskListPageState();
}

class _TaskListPageState extends State<TaskListPage> {
  final FlutterLocalNotificationsPlugin _notificationsPlugin =
      FlutterLocalNotificationsPlugin();
  List<Task> tasks = [];

  @override
  void initState() {
    super.initState();
    _initNotifications();
    _loadTasks();
  }

  Future<void> _initNotifications() async {
    const android = AndroidInitializationSettings('@mipmap/ic_launcher');
    const initSettings = InitializationSettings(android: android);

    await _notificationsPlugin.initialize(
      initSettings,
      onDidReceiveNotificationResponse: (response) {
        debugPrint('Notification tapped: ${response.payload}');
      },
    );

    // Android 13 以上では通知権限が必要
    if (await Permission.notification.isDenied) {
      await Permission.notification.request();
    }

    // 通知チャンネル作成（Android 8.0以上必須）
    const androidChannel = AndroidNotificationChannel(
      'daily_channel',
      'Daily Notifications',
      description: '毎日指定時刻に通知',
      importance: Importance.max,
    );

    final androidPlugin =
        _notificationsPlugin.resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin>();

    await androidPlugin?.createNotificationChannel(androidChannel);
    debugPrint('Notification channel created');

    debugPrint('Local timezone set to: ${tz.local.name}');
  }

  Future<void> _loadTasks() async {
    final prefs = await SharedPreferences.getInstance();
    final data = prefs.getStringList('tasks') ?? [];
    setState(() {
      tasks = data
          .map((e) => Task.fromJson(json.decode(e) as Map<String, dynamic>))
          .toList();
    });
  }

  Future<void> _saveTasks() async {
    final prefs = await SharedPreferences.getInstance();
    final data = tasks.map((e) => json.encode(e.toJson())).toList();
    await prefs.setStringList('tasks', data);
  }

  Future<void> _addTaskDialog() async {
    final nameController = TextEditingController();
    TimeOfDay? selectedTime;

    await showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('新しいタスク'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: nameController,
              decoration: const InputDecoration(labelText: 'タスク名'),
            ),
            const SizedBox(height: 8),
            ElevatedButton(
              onPressed: () async {
                final now = TimeOfDay.now();
                final picked =
                    await showTimePicker(context: context, initialTime: now);
                if (picked != null) selectedTime = picked;
              },
              child: const Text('通知時刻を設定'),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('キャンセル'),
          ),
          ElevatedButton(
            onPressed: () async {
              if (nameController.text.isNotEmpty && selectedTime != null) {
                final status = await Permission.notification.status;
                if (!status.isGranted) {
                  final result = await Permission.notification.request();
                  if (!result.isGranted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('通知権限が必要です')),
                    );
                    return;
                  }
                }

                setState(() {
                  tasks.add(
                      Task(name: nameController.text, time: selectedTime!));
                });
                await _saveTasks();
                await _scheduleDailyNotification(
                    tasks.length - 1, nameController.text, selectedTime!);
                Navigator.pop(context);
              }
            },
            child: const Text('追加'),
          ),
        ],
      ),
    );
  }

  Future<void> _scheduleDailyNotification(
      int id, String title, TimeOfDay time) async {
    final exactAllowed = await AlarmPermission.areExactAlarmsAllowed();
    if (!exactAllowed) {
      debugPrint('Exact alarms NOT allowed. 通知が正確に動作しない可能性があります');
    }

    final now = tz.TZDateTime.now(tz.local);
    var scheduled = tz.TZDateTime(
      tz.local,
      now.year,
      now.month,
      now.day,
      time.hour,
      time.minute,
    );
    if (scheduled.isBefore(now))
      scheduled = scheduled.add(const Duration(days: 1));

    final androidDetails = AndroidNotificationDetails(
      'daily_channel',
      'Daily Notifications',
      channelDescription: '毎日指定時刻に通知',
      importance: Importance.max,
      priority: Priority.high,
      playSound: true,
      enableVibration: true,
    );
    final details = NotificationDetails(android: androidDetails);

    // 🔹 ここから AlarmManager 経由で正確に通知
    final androidPlugin =
        _notificationsPlugin.resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin>();

    if (androidPlugin != null && exactAllowed) {
      await AlarmPermission.scheduleExactAlarm(
        id,
        scheduled,
        'タスク通知',
        title,
      );
      debugPrint('Scheduled daily notification at $scheduled via AlarmManager');
    }
  }

  // 🔹 テスト通知（10秒後）
  Future<void> _testNotification() async {
    // Exact Alarm 権限チェック
    final exactAllowed = await AlarmPermission.areExactAlarmsAllowed();
    if (!exactAllowed) {
      debugPrint('Exact alarms NOT allowed. スケジュール通知は不正確になる可能性があります');
    }

    final now = tz.TZDateTime.now(tz.local);
    final scheduled = now.add(const Duration(seconds: 10));

    debugPrint('Now: $now');
    debugPrint('Scheduled: $scheduled');

    // 🔹 即時通知（デバッグ用）
    const androidDetails = AndroidNotificationDetails(
      'daily_channel',
      'Daily Notifications',
      channelDescription: '今すぐ通知テストです',
      importance: Importance.max,
      priority: Priority.high,
      playSound: true,
      enableVibration: true,
    );
    const details = NotificationDetails(android: androidDetails);

    await _notificationsPlugin.show(
      9998,
      '即時通知',
      '今すぐ通知テストです',
      details,
    );

    // 🔹 10秒後に正確通知（AlarmManager を使う）
    await AlarmPermission.scheduleExactAlarm(
      9999,
      scheduled,
      'スケジュール通知',
      '10秒後の通知テストです',
    );

    debugPrint('[TestNotification] Exact alarm scheduled successfully');
  }

  Future<void> _cancelNotification(int id) async {
    await _notificationsPlugin.cancel(id);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('SimpleNotification')),
      body: ListView.builder(
        itemCount: tasks.length,
        itemBuilder: (context, i) {
          final task = tasks[i];
          return Card(
            margin: const EdgeInsets.all(8),
            child: ListTile(
              title: Text(task.name),
              subtitle: Text(
                '${task.time.hour.toString().padLeft(2, '0')}:${task.time.minute.toString().padLeft(2, '0')} に通知',
              ),
              trailing: IconButton(
                icon: const Icon(Icons.delete),
                onPressed: () {
                  setState(() {
                    _cancelNotification(i);
                    tasks.removeAt(i);
                  });
                  _saveTasks();
                },
              ),
            ),
          );
        },
      ),
      floatingActionButton: Column(
        mainAxisAlignment: MainAxisAlignment.end,
        children: [
          FloatingActionButton(
            heroTag: 'test',
            onPressed: _testNotification,
            tooltip: 'テスト通知（10秒後）',
            backgroundColor: Colors.orange,
            child: const Icon(Icons.notifications_active),
          ),
          const SizedBox(height: 12),
          FloatingActionButton(
            heroTag: 'add',
            onPressed: _addTaskDialog,
            tooltip: 'タスクを追加',
            child: const Icon(Icons.add),
          ),
        ],
      ),
    );
  }
}
