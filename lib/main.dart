import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import 'app/session.dart';
import 'app/settings.dart';
import 'ui/home_screen.dart';
import 'ui/theme.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
  final settings = Settings();
  await settings.load();
  runApp(BoxsterSrsApp(settings: settings));
}

class BoxsterSrsApp extends StatelessWidget {
  const BoxsterSrsApp({super.key, required this.settings});
  final Settings settings;

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        ChangeNotifierProvider<Settings>.value(value: settings),
        ChangeNotifierProvider<Session>(create: (_) => Session(settings)),
      ],
      child: MaterialApp(
        title: 'Boxster SRS',
        debugShowCheckedModeBanner: false,
        theme: buildTheme(),
        home: const HomeScreen(),
      ),
    );
  }
}
