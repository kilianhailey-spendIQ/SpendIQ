import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'theme.dart';
import 'package:flutter/gestures.dart';
import 'nav.dart';
import 'package:spendiq/services/master_spreadsheet_service.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// Main entry point for the application
///
/// This sets up:
/// - go_router navigation
/// - Material 3 theming with light/dark modes
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Optional: initialize Supabase when environment variables are provided.
  // This keeps the app runnable in offline/local mode while enabling Storage-backed
  // master spreadsheet updates when configured.
  // NOTE: Dreamflow’s Supabase connector doesn’t always pass `--dart-define` values
  // into Preview. The anon key is public (safe to ship) so we provide a sane
  // default for this connected project while still allowing overrides.
  const supabaseUrl = String.fromEnvironment('SUPABASE_URL', defaultValue: 'https://pawyrcjodzfzupuyiybb.supabase.co');
  const supabaseAnonKey = String.fromEnvironment(
    'SUPABASE_ANON_KEY',
    defaultValue:
        'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InBhd3lyY2pvZHpmenVwdXlpeWJiIiwicm9sZSI6ImFub24iLCJpYXQiOjE3NzMwMjQ1MjYsImV4cCI6MjA4ODYwMDUyNn0.jH7-Hd9cCM52Z0wjLqsVlUoYYskXJrLOObAhSKdOww8',
  );
  if (supabaseUrl.isNotEmpty && supabaseAnonKey.isNotEmpty) {
    try {
      await Supabase.initialize(url: supabaseUrl, anonKey: supabaseAnonKey);
      debugPrint('Supabase initialized.');
    } catch (e) {
      debugPrint('Supabase initialize failed (continuing offline): $e');
    }
  } else {
    debugPrint('Supabase not configured (SUPABASE_URL / SUPABASE_ANON_KEY). Running offline.');
  }

  // Startup optimization:
  // On Flutter Web, decoding the XLSX can block the main thread and make early UI
  // feel slow. We only prewarm from a lightweight local cache here (if available).
  // Full XLSX decoding still happens on-demand if no cache exists yet.
  unawaited(MasterSpreadsheetService.prewarmFromCache());
  // Also kick off a background full load so categorization has Merchant Master data
  // ready by the time the user uploads/parses. (Still safe: falls back offline.)
  unawaited(MasterSpreadsheetService.ensureLoaded());
  // Improve visibility of runtime errors in the Dreamflow Debug Console
  FlutterError.onError = (FlutterErrorDetails details) {
    FlutterError.presentError(details);
    debugPrint('FlutterError: \n${details.exceptionAsString()}');
    if (details.stack != null) {
      debugPrint(details.stack.toString());
    }
  };

  // Catch uncaught async errors too (e.g., in microtasks, futures)
  PlatformDispatcher.instance.onError = (Object error, StackTrace stack) {
    debugPrint('PlatformDispatcher error: '+ error.toString());
    debugPrint(stack.toString());
    return true; // mark as handled so the app doesn't crash silently
  };

  // Avoid explicit zone manipulation to prevent Zone mismatch on web.
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    // As you extend the app, use MultiProvider to wrap the app
    // and provide state to all widgets
    // Example:
    // return MultiProvider(
    //   providers: [
    //     ChangeNotifierProvider(create: (_) => ExampleProvider()),
    //   ],
    //   child: MaterialApp.router(
    //     title: 'SpendIQ',
    //     debugShowCheckedModeBanner: false,
    //     routerConfig: AppRouter.router,
    //   ),
    // );
    return MaterialApp.router(
      title: 'SpendIQ',
      debugShowCheckedModeBanner: false,

      // Theme configuration
      theme: lightTheme,
      darkTheme: darkTheme,
      themeMode: ThemeMode.system,

      // Improve desktop/web scrolling (mouse, trackpad, stylus)
      scrollBehavior: const MaterialScrollBehavior().copyWith(
        dragDevices: {
          PointerDeviceKind.touch,
          PointerDeviceKind.mouse,
          PointerDeviceKind.stylus,
        },
      ),

      // Router configuration
      routerConfig: AppRouter.router,
    );
  }
}
