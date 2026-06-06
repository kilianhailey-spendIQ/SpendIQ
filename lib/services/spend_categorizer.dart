// The file intentionally contains legacy/experimental helpers used for debugging
// and future improvements. Some are currently unused but kept for quick iteration.
// ignore_for_file: unused_element

import 'package:flutter/foundation.dart';
import 'package:spendiq/core/categories.dart';
import 'package:spendiq/services/master_spreadsheet_service.dart';

/// Returns Level 1, Level 2, Level 3(brand), and Special Logic labels
/// based on merchant/description heuristics.
class SpendCategorizer {
  /// Primary entry point. All inputs are treated case-insensitively.
  static Categorization categorize({required String merchant, String? description}) {
    final m = merchant.trim();
    final d = (description ?? merchant).trim();
    try {
      // Merchant Master is the source of truth:
      // - If we match a master row, apply Level 1 / Level 2 exactly as written.
      // - If we do NOT match a master row, do not guess with heuristics.
      //   (User request: remove hardcoded rules and follow the Master sheet.)
      final master = MasterSpreadsheetService.matchMerchantMaster('$m $d');
      if (master == null) return const Categorization(level1: Level1Categories.other, level2: 'Other');

      final l1 = _normalizeMasterLabel(master.row.level1) ?? Level1Categories.other;
      final l2 = _normalizeMasterLabel(master.row.level2) ?? 'Other';

      // If the master sheet says Level 1 is Other (or is empty), force Level 2 to Other.
      if (l1.trim().toLowerCase() == 'other') return const Categorization(level1: Level1Categories.other, level2: 'Other');
      return Categorization(level1: l1, level2: l2);
    } catch (e) {
      debugPrint('SpendCategorizer.categorize error: $e');
      return const Categorization(level1: Level1Categories.other);
    }
  }

  /// Debug/explain categorization.
  ///
  /// Use this to understand *which keyword* triggered the chosen labels.
  static CategorizationExplain explain({required String merchant, String? description}) {
    final m = merchant.trim();
    final d = (description ?? merchant).trim();
    try {
      final s = '${m.toLowerCase()} ${d.toLowerCase()}';
      // Keep explain path aligned with runtime categorization.
      final master = MasterSpreadsheetService.matchMerchantMaster('$m $d');
      if (master == null) {
        return CategorizationExplain(
          input: CategorizationInput(merchant: m, description: d, joinedLower: s),
          level1: const CategorizationDecision(level: 1, label: Level1Categories.other, matchedKeyword: null, matchGroup: 'no_master_match'),
          level2: const CategorizationDecision(level: 2, label: 'Other', matchedKeyword: null, matchGroup: 'no_master_match'),
          level3: const CategorizationDecision(level: 3, label: '', matchedKeyword: null, matchGroup: 'no_master_match'),
          special: '',
          result: const Categorization(level1: Level1Categories.other, level2: 'Other'),
        );
      }

      final l1 = _normalizeMasterLabel(master.row.level1) ?? Level1Categories.other;
      final l2 = _normalizeMasterLabel(master.row.level2) ?? 'Other';
      final isOther = l1.trim().toLowerCase() == 'other';

      final l1Decision = CategorizationDecision(level: 1, label: isOther ? Level1Categories.other : l1, matchedKeyword: master.key, matchGroup: 'merchant_master');
      final l2Decision = CategorizationDecision(level: 2, label: isOther ? 'Other' : l2, matchedKeyword: master.key, matchGroup: 'merchant_master');
      return CategorizationExplain(
        input: CategorizationInput(merchant: m, description: d, joinedLower: s),
        level1: l1Decision,
        level2: l2Decision,
        level3: const CategorizationDecision(level: 3, label: '', matchedKeyword: null, matchGroup: 'master_only'),
        special: '',
        result: Categorization(level1: l1Decision.label, level2: l2Decision.label, level3: '', special: ''),
      );
    } catch (e) {
      debugPrint('SpendCategorizer.explain error: $e');
      const fallback = Level1Categories.other;
      return CategorizationExplain(
        input: CategorizationInput(merchant: m, description: d, joinedLower: '${m.toLowerCase()} ${d.toLowerCase()}'),
        level1: const CategorizationDecision(level: 1, label: fallback, matchedKeyword: null, matchGroup: 'error_fallback'),
        level2: const CategorizationDecision(level: 2, label: 'Other', matchedKeyword: null, matchGroup: 'error_fallback'),
        level3: const CategorizationDecision(level: 3, label: '', matchedKeyword: null, matchGroup: 'error_fallback'),
        special: '',
        result: const Categorization(level1: fallback),
      );
    }
  }

  static String? _normalizeLevel1(String? raw) {
    if (raw == null) return null;
    final v = raw.trim();
    if (v.isEmpty) return null;
    // Common normalization for legacy sheets that had Travel subtypes in Level 1.
    if (v.toLowerCase().contains('travel')) return Level1Categories.travel;
    // Exact match first.
    if (Level1Categories.all.contains(v)) return v;
    // Loose match (ignore punctuation/spacing).
    String n(String s) => s.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), '');
    final vn = n(v);
    for (final cat in Level1Categories.all) {
      if (n(cat) == vn) return cat;
    }
    return null;
  }

  static String? _normalizeMasterLabel(String? raw) {
    if (raw == null) return null;
    final v = raw.trim();
    if (v.isEmpty) return null;
    
    // Map short category names from master spreadsheet to full category names in code
    final normalized = v.toLowerCase();
    
    // Category alias mappings (spreadsheet name -> code constant)
    const categoryAliases = {
      'gas': Level1Categories.gas, // "Gas" -> "Gas & Fuel"
      'fuel': Level1Categories.gas,
      'retail': Level1Categories.onlineRetail, // "Retail" -> "Online Retail"
      'online retail': Level1Categories.onlineRetail,
      'streaming': Level1Categories.streaming, // "Streaming" -> "Streaming & Subscriptions"
      'subscriptions': Level1Categories.streaming,
      'fitness': Level1Categories.fitness, // "Fitness" -> "Fitness"
      'gym': Level1Categories.fitness,
      'drugstores': Level1Categories.drugstores, // "Drugstores" -> "Drugstores & Pharmacies"
      'pharmacy': Level1Categories.drugstores,
      'pharmacies': Level1Categories.drugstores,
      'wholesale': Level1Categories.wholesale, // "Wholesale" -> "Wholesale Clubs"
      'wholesale clubs': Level1Categories.wholesale,
      'general merchandise': Level1Categories.generalMerch,
      'services': Level1Categories.business, // "Services" -> "Services & Software"
      'software': Level1Categories.business,
    };
    
    // Check for exact alias match
    if (categoryAliases.containsKey(normalized)) {
      return categoryAliases[normalized];
    }
    
    // Check if it already matches a Level1 category exactly
    if (Level1Categories.all.contains(v)) return v;
    
    // Fuzzy match: normalize by removing punctuation and comparing
    String n(String s) => s.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), '');
    final vn = n(v);
    for (final cat in Level1Categories.all) {
      if (n(cat) == vn) return cat;
    }
    
    // No match found - return original value
    return v;
  }

  // ---- Level 1 ----
  static String _detectLevel1(String merchant, String description) {
    final s = '${merchant.toLowerCase()} ${description.toLowerCase()}';
    bool any(List<String> keys) => keys.any((k) => s.contains(k));

    if (any(['whole foods','trader joe','kroger','safeway','aldi','grocery','market'])) return Level1Categories.groceries;
    if (any(['mcdonald','starbucks','chipotle','taco bell','tacobell','restaurant','cafe','eatery','pizza','ubereats','doordash','grubhub','deli','coffee'])) return Level1Categories.dining;
    if (any(['shell','chevron','exxon','bp ','fuel',' gas '])) return Level1Categories.gas;
    if (any([
      'delta',
      'united',
      'american airlines',
      'southwest',
      'jetblue',
      'alaska',
      'airfare',
      'airline',
      'flight',
      'marriott',
      'hilton',
      'hyatt',
      'ihg',
      'airbnb',
      'hotel',
      'inn',
      'resort',
      'avis',
      'hertz',
      'enterprise',
      'alamo',
      'national car',
      'budget car',
      'uber',
      'lyft',
      'metro',
      'mta',
      'bart',
      'transit',
      'bus',
      'train',
      'subway',
      'rideshare',
      'parking',
      'toll',
    ])) {
      return Level1Categories.travel;
    }
    if (any(['amazon','etsy','ebay','shopify','wayfair','shein'])) return Level1Categories.onlineRetail;
    if (any(["sam's club","sam's",'bjs','bj\'s','costco','wholesale'])) return Level1Categories.wholesale;
    if (any(['netflix','spotify','hulu','disney+','max ','paramount+','onlyfans','patreon','subscription'])) return Level1Categories.streaming;
    if (any(['cvs','walgreens','rite aid','pharmacy'])) return Level1Categories.drugstores;
    if (any(['pg&e','duke energy','coned','electric','utility','water','gas utility'])) return Level1Categories.utilities;
    if (any(['geico','progressive','allstate','state farm','insurance'])) return Level1Categories.insurance;
    if (any(['clinic','hospital','dentist','optometry','urgent care','medical','healthcare'])) return Level1Categories.healthcare;
    if (any(['walmart','target','best buy','apple','electronics','department store','general store'])) return Level1Categories.generalMerch;
    if (any(['amc','regal','theater','concert','museum','zoo','eventbrite','ticketmaster','gaming','steam','playstation','xbox'])) return Level1Categories.entertainment;
    if (any(['aws','azure','google cloud','adobe','zoom','slack','atlassian','notion','mailchimp','business'])) return Level1Categories.business;
    return Level1Categories.other;
  }

  static CategorizationDecision _detectLevel1WithExplain(String merchant, String description) {
    final s = '${merchant.toLowerCase()} ${description.toLowerCase()}';
    final rules = <String, List<String>>{
      Level1Categories.groceries: ['whole foods', 'trader joe', 'kroger', 'safeway', 'aldi', 'grocery', 'market'],
      Level1Categories.dining: ['mcdonald', 'starbucks', 'chipotle', 'taco bell', 'tacobell', 'restaurant', 'cafe', 'eatery', 'pizza', 'ubereats', 'doordash', 'grubhub', 'deli', 'coffee'],
      Level1Categories.gas: ['shell', 'chevron', 'exxon', 'bp ', 'fuel', ' gas '],
      Level1Categories.travel: [
        'delta',
        'united',
        'american airlines',
        'southwest',
        'jetblue',
        'alaska',
        'airfare',
        'airline',
        'flight',
        'marriott',
        'hilton',
        'hyatt',
        'ihg',
        'airbnb',
        'hotel',
        'inn',
        'resort',
        'avis',
        'hertz',
        'enterprise',
        'alamo',
        'national car',
        'budget car',
        'uber',
        'lyft',
        'metro',
        'mta',
        'bart',
        'transit',
        'bus',
        'train',
        'subway',
        'rideshare',
        'parking',
        'toll',
      ],
      Level1Categories.onlineRetail: ['amazon', 'etsy', 'ebay', 'shopify', 'wayfair', 'shein'],
      Level1Categories.wholesale: ["sam's club", "sam's", 'bjs', "bj's", 'costco', 'wholesale'],
      Level1Categories.streaming: ['netflix', 'spotify', 'hulu', 'disney+', 'max ', 'paramount+', 'onlyfans', 'patreon', 'subscription'],
      Level1Categories.drugstores: ['cvs', 'walgreens', 'rite aid', 'pharmacy'],
      Level1Categories.utilities: ['pg&e', 'duke energy', 'coned', 'electric', 'utility', 'water', 'gas utility'],
      Level1Categories.insurance: ['geico', 'progressive', 'allstate', 'state farm', 'insurance'],
      Level1Categories.healthcare: ['clinic', 'hospital', 'dentist', 'optometry', 'urgent care', 'medical', 'healthcare'],
      Level1Categories.generalMerch: ['walmart', 'target', 'best buy', 'apple', 'electronics', 'department store', 'general store'],
      Level1Categories.entertainment: ['amc', 'regal', 'theater', 'concert', 'museum', 'zoo', 'eventbrite', 'ticketmaster', 'gaming', 'steam', 'playstation', 'xbox'],
      Level1Categories.business: ['aws', 'azure', 'google cloud', 'adobe', 'zoom', 'slack', 'atlassian', 'notion', 'mailchimp', 'business'],
    };

    for (final entry in rules.entries) {
      for (final kw in entry.value) {
        if (s.contains(kw)) {
          return CategorizationDecision(level: 1, label: entry.key, matchedKeyword: kw, matchGroup: 'contains');
        }
      }
    }
    return const CategorizationDecision(level: 1, label: Level1Categories.other, matchedKeyword: null, matchGroup: 'fallback');
  }

  // ---- Level 2 ----
  static String _detectLevel2({required String level1, required String merchant, required String description}) {
    final s = '${merchant.toLowerCase()} ${description.toLowerCase()}';
    bool any(List<String> keys) => keys.any((k) => s.contains(k));
    switch (level1) {
      case Level1Categories.groceries:
        if (any(['costco','bjs','bj\'s',"sam's"])) return 'Wholesale Club';
        if (any(['trader joe','whole foods','kroger','safeway','aldi','market'])) return 'Supermarket';
        return 'Specialty Food';
      case Level1Categories.dining:
        if (any(['ubereats','doordash','grubhub','postmates'])) return 'Delivery';
        if (any(['coffee','cafe','starbucks'])) return 'Coffee & Cafe';
        return 'Restaurant';
      case Level1Categories.gas:
        if (any(['costco','sam\'s','bj\'s'])) return 'Warehouse Club Gas';
        if (any(['kroger','safeway','giant','h-e-b'])) return 'Grocery Gas';
        return 'Major Gas Station';
      case Level1Categories.travel:
        // Level 2 should be the specific travel spend type.
        if (any(['delta','united','american airlines','southwest','jetblue','alaska','airfare','airline','flight'])) return 'Airfare';
        if (any(['marriott','hilton','hyatt','ihg','hotel','inn','resort'])) return 'Hotels';
        if (any(['airbnb','vrbo'])) return 'Lodging';
        if (any(['avis','hertz','enterprise','alamo','national car','budget car','car rental'])) return 'Car Rental';
        if (any(['uber','lyft'])) return 'Rideshare';
        if (any(['metro','mta','bart','transit','bus','train','subway'])) return 'Transit';
        if (any(['parking'])) return 'Parking';
        if (any(['toll','ezpass','fastrak'])) return 'Tolls';
        return 'Travel';
      case Level1Categories.onlineRetail:
        if (any(['amazon','ebay','etsy'])) return 'Marketplace';
        return 'Direct-to-Consumer';
      case Level1Categories.generalMerch:
        if (any(['clothing','apparel','tj maxx','macy','nordstrom','old navy','gap'])) return 'Clothing';
        if (any(['best buy','apple','electronics'])) return 'Electronics';
        if (any(['dick\'s','academy sports','sporting'])) return 'Sporting Goods';
        if (any(['sephora','ulta','beauty'])) return 'Beauty';
        if (any(['petco','petsmart','pet '])) return 'Pet Stores';
        return 'Department Store';
      case Level1Categories.streaming:
        return 'Subscription';
      case Level1Categories.drugstores:
        return 'Pharmacy';
      case Level1Categories.utilities:
        if (any(['internet','wifi','xfinity','comcast','spectrum'])) return 'Internet';
        if (any(['verizon','att','t-mobile'])) return 'Phone';
        return 'Utilities';
      case Level1Categories.insurance:
        return 'Insurance';
      case Level1Categories.healthcare:
        return 'Medical';
      case Level1Categories.entertainment:
        if (any(['amc','regal','theater','cinema'])) return 'Movies';
        if (any(['ticketmaster','eventbrite','concert'])) return 'Events';
        return 'Entertainment';
      case Level1Categories.wholesale:
        return 'Wholesale Club';
      case Level1Categories.business:
        return 'Business Service';
      default:
        return 'Other';
    }
  }

  static CategorizationDecision _detectLevel2WithExplain({required String level1, required String merchant, required String description}) {
    final s = '${merchant.toLowerCase()} ${description.toLowerCase()}';
    String? firstMatch(List<String> keys) {
      for (final k in keys) {
        if (s.contains(k)) return k;
      }
      return null;
    }

    switch (level1) {
      case Level1Categories.groceries:
        final m1 = firstMatch(['costco', 'bjs', "bj's", "sam's"]);
        if (m1 != null) return CategorizationDecision(level: 2, label: 'Wholesale Club', matchedKeyword: m1, matchGroup: 'contains');
        final m2 = firstMatch(['trader joe', 'whole foods', 'kroger', 'safeway', 'aldi', 'market']);
        if (m2 != null) return CategorizationDecision(level: 2, label: 'Supermarket', matchedKeyword: m2, matchGroup: 'contains');
        return const CategorizationDecision(level: 2, label: 'Specialty Food', matchedKeyword: null, matchGroup: 'fallback');
      case Level1Categories.dining:
        final m1 = firstMatch(['ubereats', 'doordash', 'grubhub', 'postmates']);
        if (m1 != null) return CategorizationDecision(level: 2, label: 'Delivery', matchedKeyword: m1, matchGroup: 'contains');
        final m2 = firstMatch(['coffee', 'cafe', 'starbucks']);
        if (m2 != null) return CategorizationDecision(level: 2, label: 'Coffee & Cafe', matchedKeyword: m2, matchGroup: 'contains');
        return const CategorizationDecision(level: 2, label: 'Restaurant', matchedKeyword: null, matchGroup: 'fallback');
      case Level1Categories.gas:
        final m1 = firstMatch(['costco', "sam's", "bj's"]);
        if (m1 != null) return CategorizationDecision(level: 2, label: 'Warehouse Club Gas', matchedKeyword: m1, matchGroup: 'contains');
        final m2 = firstMatch(['kroger', 'safeway', 'giant', 'h-e-b']);
        if (m2 != null) return CategorizationDecision(level: 2, label: 'Grocery Gas', matchedKeyword: m2, matchGroup: 'contains');
        return const CategorizationDecision(level: 2, label: 'Major Gas Station', matchedKeyword: null, matchGroup: 'fallback');
      case Level1Categories.travel:
        final mAir = firstMatch(['delta', 'united', 'american airlines', 'southwest', 'jetblue', 'alaska', 'airfare', 'airline', 'flight']);
        if (mAir != null) return CategorizationDecision(level: 2, label: 'Airfare', matchedKeyword: mAir, matchGroup: 'contains');
        final mHotel = firstMatch(['marriott', 'hilton', 'hyatt', 'ihg', 'hotel', 'inn', 'resort']);
        if (mHotel != null) return CategorizationDecision(level: 2, label: 'Hotels', matchedKeyword: mHotel, matchGroup: 'contains');
        final mLodging = firstMatch(['airbnb', 'vrbo']);
        if (mLodging != null) return CategorizationDecision(level: 2, label: 'Lodging', matchedKeyword: mLodging, matchGroup: 'contains');
        final mCar = firstMatch(['avis', 'hertz', 'enterprise', 'alamo', 'national car', 'budget car', 'car rental']);
        if (mCar != null) return CategorizationDecision(level: 2, label: 'Car Rental', matchedKeyword: mCar, matchGroup: 'contains');
        final mRide = firstMatch(['uber', 'lyft']);
        if (mRide != null) return CategorizationDecision(level: 2, label: 'Rideshare', matchedKeyword: mRide, matchGroup: 'contains');
        final mTransit = firstMatch(['metro', 'mta', 'bart', 'transit', 'bus', 'train', 'subway']);
        if (mTransit != null) return CategorizationDecision(level: 2, label: 'Transit', matchedKeyword: mTransit, matchGroup: 'contains');
        final mParking = firstMatch(['parking']);
        if (mParking != null) return CategorizationDecision(level: 2, label: 'Parking', matchedKeyword: mParking, matchGroup: 'contains');
        final mToll = firstMatch(['toll', 'ezpass', 'fastrak']);
        if (mToll != null) return CategorizationDecision(level: 2, label: 'Tolls', matchedKeyword: mToll, matchGroup: 'contains');
        return const CategorizationDecision(level: 2, label: 'Travel', matchedKeyword: null, matchGroup: 'fallback');
      case Level1Categories.onlineRetail:
        final m1 = firstMatch(['amazon', 'ebay', 'etsy']);
        if (m1 != null) return CategorizationDecision(level: 2, label: 'Marketplace', matchedKeyword: m1, matchGroup: 'contains');
        return const CategorizationDecision(level: 2, label: 'Direct-to-Consumer', matchedKeyword: null, matchGroup: 'fallback');
      case Level1Categories.generalMerch:
        final m1 = firstMatch(['clothing', 'apparel', 'tj maxx', 'macy', 'nordstrom', 'old navy', 'gap']);
        if (m1 != null) return CategorizationDecision(level: 2, label: 'Clothing', matchedKeyword: m1, matchGroup: 'contains');
        final m2 = firstMatch(['best buy', 'apple', 'electronics']);
        if (m2 != null) return CategorizationDecision(level: 2, label: 'Electronics', matchedKeyword: m2, matchGroup: 'contains');
        final m3 = firstMatch(["dick's", 'academy sports', 'sporting']);
        if (m3 != null) return CategorizationDecision(level: 2, label: 'Sporting Goods', matchedKeyword: m3, matchGroup: 'contains');
        final m4 = firstMatch(['sephora', 'ulta', 'beauty']);
        if (m4 != null) return CategorizationDecision(level: 2, label: 'Beauty', matchedKeyword: m4, matchGroup: 'contains');
        final m5 = firstMatch(['petco', 'petsmart', 'pet ']);
        if (m5 != null) return CategorizationDecision(level: 2, label: 'Pet Stores', matchedKeyword: m5, matchGroup: 'contains');
        return const CategorizationDecision(level: 2, label: 'Department Store', matchedKeyword: null, matchGroup: 'fallback');
      case Level1Categories.streaming:
        return const CategorizationDecision(level: 2, label: 'Subscription', matchedKeyword: null, matchGroup: 'fixed');
      case Level1Categories.drugstores:
        return const CategorizationDecision(level: 2, label: 'Pharmacy', matchedKeyword: null, matchGroup: 'fixed');
      case Level1Categories.utilities:
        final m1 = firstMatch(['internet', 'wifi', 'xfinity', 'comcast', 'spectrum']);
        if (m1 != null) return CategorizationDecision(level: 2, label: 'Internet', matchedKeyword: m1, matchGroup: 'contains');
        final m2 = firstMatch(['verizon', 'att', 't-mobile']);
        if (m2 != null) return CategorizationDecision(level: 2, label: 'Phone', matchedKeyword: m2, matchGroup: 'contains');
        return const CategorizationDecision(level: 2, label: 'Utilities', matchedKeyword: null, matchGroup: 'fallback');
      case Level1Categories.insurance:
        return const CategorizationDecision(level: 2, label: 'Insurance', matchedKeyword: null, matchGroup: 'fixed');
      case Level1Categories.healthcare:
        return const CategorizationDecision(level: 2, label: 'Medical', matchedKeyword: null, matchGroup: 'fixed');
      case Level1Categories.entertainment:
        final m1 = firstMatch(['amc', 'regal', 'theater', 'cinema']);
        if (m1 != null) return CategorizationDecision(level: 2, label: 'Movies', matchedKeyword: m1, matchGroup: 'contains');
        final m2 = firstMatch(['ticketmaster', 'eventbrite', 'concert']);
        if (m2 != null) return CategorizationDecision(level: 2, label: 'Events', matchedKeyword: m2, matchGroup: 'contains');
        return const CategorizationDecision(level: 2, label: 'Entertainment', matchedKeyword: null, matchGroup: 'fallback');
      case Level1Categories.wholesale:
        return const CategorizationDecision(level: 2, label: 'Wholesale Club', matchedKeyword: null, matchGroup: 'fixed');
      case Level1Categories.business:
        return const CategorizationDecision(level: 2, label: 'Business Service', matchedKeyword: null, matchGroup: 'fixed');
      default:
        return const CategorizationDecision(level: 2, label: 'Other', matchedKeyword: null, matchGroup: 'fallback');
    }
  }

  // ---- Level 3 brand ----
  static String _detectLevel3Brand({required String merchant, required String description}) {
    final s = (merchant.isNotEmpty ? merchant : description).trim();
    // If it matches a known store brand list, return the canonical brand label.
    for (final brand in StoreBrands.names) {
      if (s.toLowerCase().contains(brand.toLowerCase())) return brand;
    }
    // Otherwise, return a concise brand guess (first 2 words without common noise)
    final cleaned = s
        .replaceAll(RegExp(r'POS PURCHASE|ONLINE PURCHASE|ECOM|WEB|CARD\s+\d+', caseSensitive: false), '')
        .replaceAll(RegExp(r'\s+[A-Z]{2}(?:\s+USA)?$'), '')
        .trim();
    final words = cleaned.split(RegExp(r'\s+')).where((w) => w.isNotEmpty).toList();
    if (words.isEmpty) return '';
    return words.take(2).join(' ');
  }

  static CategorizationDecision _detectLevel3WithExplain({required String merchant, required String description}) {
    final s = (merchant.isNotEmpty ? merchant : description).trim();
    for (final brand in StoreBrands.names) {
      if (s.toLowerCase().contains(brand.toLowerCase())) {
        return CategorizationDecision(level: 3, label: brand, matchedKeyword: brand, matchGroup: 'store_brand_list');
      }
    }
    final cleaned = s
        .replaceAll(RegExp(r'POS PURCHASE|ONLINE PURCHASE|ECOM|WEB|CARD\s+\d+', caseSensitive: false), '')
        .replaceAll(RegExp(r'\s+[A-Z]{2}(?:\s+USA)?$'), '')
        .trim();
    final words = cleaned.split(RegExp(r'\s+')).where((w) => w.isNotEmpty).toList();
    if (words.isEmpty) return const CategorizationDecision(level: 3, label: '', matchedKeyword: null, matchGroup: 'empty');
    return CategorizationDecision(level: 3, label: words.take(2).join(' '), matchedKeyword: null, matchGroup: 'first_two_words');
  }

  // ---- Special logic column ----
  static String _detectSpecial({required String level1, required String merchant, required String description}) {
    final s = '${merchant.toLowerCase()} ${description.toLowerCase()}';
    // Implemented per request: Dining + contains "airport" => Lounge benefit
    if (level1 == Level1Categories.dining && s.contains('airport')) return 'Lounge benefit';
    return '';
  }
}

class Categorization {
  final String level1;
  final String level2;
  final String level3; // brand
  final String special;

  const Categorization({required this.level1, this.level2 = '', this.level3 = '', this.special = ''});
}

class CategorizationInput {
  final String merchant;
  final String description;
  final String joinedLower;
  const CategorizationInput({required this.merchant, required this.description, required this.joinedLower});
}

class CategorizationDecision {
  final int level;
  final String label;
  final String? matchedKeyword;
  final String matchGroup;
  const CategorizationDecision({required this.level, required this.label, required this.matchedKeyword, required this.matchGroup});
}

class CategorizationExplain {
  final CategorizationInput input;
  final CategorizationDecision level1;
  final CategorizationDecision level2;
  final CategorizationDecision level3;
  final String special;
  final Categorization result;
  const CategorizationExplain({required this.input, required this.level1, required this.level2, required this.level3, required this.special, required this.result});
}
