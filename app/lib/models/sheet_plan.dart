class SheetPlan {
  static const int slotsPerSheet = 4;

  final List<String> slots;
  final int copies;

  const SheetPlan({required this.slots, required this.copies})
      : assert(slots.length == slotsPerSheet);

  bool get isPure => slots.toSet().length == 1;

  Map<String, int> get composition {
    final counts = <String, int>{};
    for (final id in slots) {
      counts[id] = (counts[id] ?? 0) + 1;
    }
    return counts;
  }

  int get totalPrints => slotsPerSheet * copies;

  /// Just the number of copies — e.g. "10.jpg" means "print 10 copies of this sheet".
  /// User explicitly requested this format. Duplicates handled at attachment time.
  String get filename => '$copies.jpg';

  /// The detailed/legacy filename, useful for human-readable email body listing.
  String get descriptiveName {
    final parts = composition.entries.toList()
      ..sort((a, b) {
        final byCount = b.value.compareTo(a.value);
        return byCount != 0 ? byCount : a.key.compareTo(b.key);
      });
    if (isPure) {
      return '${parts.first.key} × $copies copies';
    }
    final mix = parts.map((e) => '${e.key} ×${e.value}').join(', ');
    return 'Mixed sheet ($mix) × $copies copy';
  }

  @override
  String toString() => '$filename copies=$copies slots=$slots';
}

class PackingResult {
  final List<SheetPlan> sheets;
  final Map<String, int> requestedByDesign;
  final Map<String, int> producedByDesign;

  const PackingResult({
    required this.sheets,
    required this.requestedByDesign,
    required this.producedByDesign,
  });

  int get totalSheetsToPrint => sheets.fold(0, (sum, s) => sum + s.copies);
  int get totalPrintsRequested => requestedByDesign.values.fold(0, (a, b) => a + b);
  int get totalPrintsProduced => producedByDesign.values.fold(0, (a, b) => a + b);
  int get extras => totalPrintsProduced - totalPrintsRequested;

  Map<String, int> get extrasByDesign {
    final out = <String, int>{};
    for (final id in requestedByDesign.keys) {
      final extra = (producedByDesign[id] ?? 0) - (requestedByDesign[id] ?? 0);
      if (extra > 0) out[id] = extra;
    }
    return out;
  }
}
