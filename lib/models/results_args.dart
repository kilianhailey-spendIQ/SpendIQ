import 'package:spendiq/models/transaction.dart';

/// Arguments passed to ResultsPage via go_router `state.extra`.
class ResultsArgs {
  final List<SpendTransaction> transactions;
  /// The user-selected number of months represented by the uploaded statements.
  /// Used to annualize projections when < 12.
  final int monthsInUpload;

  const ResultsArgs({required this.transactions, required this.monthsInUpload});
}
