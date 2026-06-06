import 'package:go_router/go_router.dart';
import 'package:spendiq/pages/landing_page.dart';
import 'package:spendiq/pages/pricing_page.dart';
import 'package:spendiq/pages/upload_page.dart';
import 'package:spendiq/pages/results_page.dart';
import 'package:spendiq/pages/backend_debug_page.dart';
import 'package:spendiq/pages/auth_page.dart';
import 'package:spendiq/pages/account_page.dart';
import 'package:spendiq/models/transaction.dart';
import 'package:spendiq/models/results_args.dart';

/// GoRouter configuration for app navigation
///
/// This uses go_router for declarative routing, which provides:
/// - Type-safe navigation
/// - Deep linking support (web URLs, app links)
/// - Easy route parameters
/// - Navigation guards and redirects
///
/// To add a new route:
/// 1. Add a route constant to AppRoutes below
/// 2. Add a GoRoute to the routes list
/// 3. Navigate using context.go() or context.push()
/// 4. Use context.pop() to go back.
class AppRouter {
  static final GoRouter router = GoRouter(
    initialLocation: AppRoutes.landing,
    debugLogDiagnostics: true,
    routes: [
      GoRoute(
        path: AppRoutes.landing,
        name: 'landing',
        pageBuilder: (context, state) => const NoTransitionPage(child: LandingPage()),
      ),
      GoRoute(
        path: AppRoutes.pricing,
        name: 'pricing',
        pageBuilder: (context, state) => const NoTransitionPage(child: PricingPage()),
      ),
      GoRoute(
        path: AppRoutes.upload,
        name: 'upload',
        pageBuilder: (context, state) => const NoTransitionPage(child: UploadPage()),
      ),
      GoRoute(
        path: AppRoutes.results,
        name: 'results',
        // Use builder so we can access state.extra and pass data to the page.
        // Note: ResultsPage will check subscription status in its own initState
        builder: (context, state) {
          final extra = state.extra;
          if (extra is ResultsArgs) {
            return ResultsPage(transactions: extra.transactions, monthsInUpload: extra.monthsInUpload);
          }

          final txs = (extra is List<SpendTransaction>) ? extra : (extra is List) ? extra.whereType<SpendTransaction>().toList() : <SpendTransaction>[];
          return ResultsPage(transactions: txs);
        },
      ),
      GoRoute(
        path: AppRoutes.backendDebug,
        name: 'backendDebug',
        pageBuilder: (context, state) => const NoTransitionPage(child: BackendDebugPage()),
      ),
      GoRoute(
        path: AppRoutes.auth,
        name: 'auth',
        pageBuilder: (context, state) => const NoTransitionPage(child: AuthPage()),
      ),
      GoRoute(
        path: AppRoutes.account,
        name: 'account',
        pageBuilder: (context, state) => const NoTransitionPage(child: AccountPage()),
      ),
    ],
  );
}

/// Route path constants
/// Use these instead of hard-coding route strings
class AppRoutes {
  static const String landing = '/';
  static const String pricing = '/pricing';
  static const String upload = '/upload';
  static const String results = '/results';
  static const String backendDebug = '/backend-debug';
  static const String auth = '/auth';
  static const String account = '/account';
}
