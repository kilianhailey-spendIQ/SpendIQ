/// Level 1 – Core Spend Categories (exactly one per transaction)
class Level1Categories {
  static const dining = 'Dining';
  static const groceries = 'Groceries';
  static const gas = 'Gas & Fuel';
  /// Basic travel category. Use Level 2 for specifics (Airfare, Hotels, Transit, etc.).
  static const travel = 'Travel';
  static const onlineRetail = 'Online Retail';
  static const wholesale = 'Wholesale Clubs';
  static const streaming = 'Streaming & Subscriptions';
  static const drugstores = 'Drugstores & Pharmacies';
  static const utilities = 'Utilities';
  static const insurance = 'Insurance';
  static const healthcare = 'Healthcare';
  static const generalMerch = 'General Merchandise';
  static const entertainment = 'Entertainment';
  static const fitness = 'Fitness'; // New category for gym/fitness spending
  static const business = 'Services & Software';
  static const other = 'Other';

  static const all = <String>{
    dining,
    groceries,
    gas,
    travel,
    onlineRetail,
    wholesale,
    streaming,
    drugstores,
    utilities,
    insurance,
    healthcare,
    generalMerch,
    entertainment,
    fitness,
    business,
    other,
  };
}

/// Store-specific brands that often have elevated rewards with co-branded cards.
class StoreBrands {
  static const List<String> names = [
    'Target', 'TJ Maxx', 'Amazon', 'Costco', 'Walmart', 'Best Buy', 'Apple',
    // Airlines
    'Delta', 'United', 'American Airlines', 'Southwest',
    // Hotels
    'Marriott', 'Hilton', 'Hyatt',
  ];
}
