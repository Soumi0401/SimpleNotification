import 'package:flutter/material.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:timezone/data/latest.dart' as tz;
import 'package:timezone/timezone.dart' as tz;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:permission_handler/permission_handler.dart';
import 'dart:convert';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  tz.initializeTimeZones();
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
    await _notificationsPlugin.initialize(initSettings);

    // 🔔 Android 13以降では通知権限が必要
    if (await Permission.notification.isDenied) {
      await Permission.notification.request();
    }
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
                if (picked != null) {
                  selectedTime = picked;
                }
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
                // 権限チェック
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
    final now = tz.TZDateTime.now(tz.local);
    var scheduled = tz.TZDateTime(
      tz.local,
      now.year,
      now.month,
      now.day,
      time.hour,
      time.minute,
    );
    if (scheduled.isBefore(now)) {
      scheduled = scheduled.add(const Duration(days: 1));
    }

    const androidDetails = AndroidNotificationDetails(
      'daily_channel',
      'Daily Notifications',
      channelDescription: '毎日指定時刻に通知',
      importance: Importance.high,
      priority: Priority.high,
    );
    const details = NotificationDetails(android: androidDetails);

    await _notificationsPlugin.zonedSchedule(
      id,
      'タスク通知',
      title,
      scheduled,
      details,
      androidAllowWhileIdle: true,
      uiLocalNotificationDateInterpretation:
          UILocalNotificationDateInterpretation.absoluteTime,
      matchDateTimeComponents: DateTimeComponents.time, // 毎日繰り返し
    );
  }

  Future<void> _cancelNotification(int id) async {
    await _notificationsPlugin.cancel(id);
  }

  Future<void> _testNotification() async {
    final now = tz.TZDateTime.now(tz.local);
    final scheduled = now.add(const Duration(seconds: 5));

    const androidDetails = AndroidNotificationDetails(
      'daily_channel',
      'Daily Notifications',
      channelDescription: '5秒後にテスト通知を送信',
      importance: Importance.high,
      priority: Priority.high,
    );
    const details = NotificationDetails(android: androidDetails);

    await _notificationsPlugin.zonedSchedule(
      9999, // ← 適当なID（他と重複しないように）
      'テスト通知',
      '5秒後の通知テストです',
      scheduled,
      details,
      androidAllowWhileIdle: true,
      uiLocalNotificationDateInterpretation:
          UILocalNotificationDateInterpretation.absoluteTime,
    );
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

      // ✅ テスト通知ボタン＋追加ボタンの2段構成
      floatingActionButton: Column(
        mainAxisAlignment: MainAxisAlignment.end,
        children: [
          FloatingActionButton(
            heroTag: 'test',
            onPressed: _testNotification,
            tooltip: '5秒後に通知テスト',
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
