import '../models/order_line.dart';
import '../models/sheet_plan.dart';

class Packer {
  /// Adaptive slot-stable packer.
  ///
  /// Goal: minimize the number of `[D,D,D,D]` single-design sheets while
  /// keeping each design pinned to a home corner (UL/UR/LL/LR) for as long
  /// as it has remaining quantity. The cut-stack story: when sheets are
  /// stacked and guillotine-cut, each cut quarter stack is a contiguous
  /// block of the same design and sorting is trivial.
  ///
  /// Three phases:
  ///
  /// **Phase A — 4+ distinct designs still need prints.** Top 4 fill the
  /// four corners (each in its own slot). One template, copies = min of
  /// the four remaining quantities. As designs finish, their corner frees
  /// up and the next design from the wait queue takes over.
  ///
  /// **Phase B — 2 or 3 distinct designs left.** Empty corners are
  /// re-used by the still-active designs, weighted by their remaining
  /// quantity so the dominant gets extra slots and finishes alongside the
  /// minors. Each active design keeps its home corner; the extra corners
  /// are "filler" duplicates.
  ///
  /// **Phase C — 1 distinct design left.** Single-design `[D,D,D,D]`
  /// sheets, with the final sheet padded by extras. This is the only
  /// place all-same sheets are produced — and only when no other design
  /// is available to mix with.
  static PackingResult pack(List<OrderLine> lines) {
    final cleaned = lines
        .where((l) => l.designId.trim().isNotEmpty && l.quantity > 0)
        .toList();
    if (cleaned.isEmpty) {
      return const PackingResult(
        sheets: [],
        requestedByDesign: {},
        producedByDesign: {},
      );
    }

    final requested = <String, int>{};
    for (final l in cleaned) {
      requested[l.designId] = (requested[l.designId] ?? 0) + l.quantity;
    }

    final remaining = Map<String, int>.from(requested);

    // Designs sorted by qty desc (alpha tiebreak) so corner assignment
    // is deterministic and the biggest run gets the leftmost corner.
    final orderedDesigns = remaining.entries.toList()
      ..sort((a, b) {
        final byQty = b.value.compareTo(a.value);
        return byQty != 0 ? byQty : a.key.compareTo(b.key);
      });
    final designIds = orderedDesigns.map((e) => e.key).toList();
    var nextDesignIdx = 0;

    // Each design tracks its home corner (0=UL, 1=UR, 2=LL, 3=LR).
    final homeCorner = <String, int>{};
    // Current occupants of each corner.
    final corners = List<String?>.filled(SheetPlan.slotsPerSheet, null);

    String? popFromQueue() {
      while (nextDesignIdx < designIds.length) {
        final candidate = designIds[nextDesignIdx++];
        if ((remaining[candidate] ?? 0) > 0 && !corners.contains(candidate)) {
          return candidate;
        }
      }
      return null;
    }

    // Seed corners with the first up-to-4 designs.
    for (var i = 0; i < SheetPlan.slotsPerSheet; i++) {
      final d = popFromQueue();
      if (d == null) break;
      corners[i] = d;
      homeCorner[d] = i;
    }

    final rawSheets = <SheetPlan>[];

    while (true) {
      // Free corners whose owner just finished, then try to refill them.
      for (var i = 0; i < SheetPlan.slotsPerSheet; i++) {
        final owner = corners[i];
        if (owner != null && remaining[owner]! <= 0) {
          corners[i] = null;
        }
      }
      for (var i = 0; i < SheetPlan.slotsPerSheet; i++) {
        if (corners[i] == null) {
          final d = popFromQueue();
          if (d == null) break;
          corners[i] = d;
          homeCorner[d] = i;
        }
      }

      final activeCorners = corners.where((c) => c != null).toList().cast<String>();
      if (activeCorners.isEmpty) break;

      if (activeCorners.length == SheetPlan.slotsPerSheet) {
        // Phase A — all 4 corners taken by distinct designs.
        final template = corners.map((c) => c!).toList();
        final qtys = template.map((d) => remaining[d]!).toList();
        final copies = qtys.reduce((a, b) => a < b ? a : b);
        rawSheets.add(SheetPlan(slots: template, copies: copies));
        for (final d in template) {
          remaining[d] = remaining[d]! - copies;
        }
      } else if (activeCorners.length >= 2) {
        // Phase B — 2 or 3 distinct designs. Distribute the empty corners
        // among them proportionally to remaining qty so the dominant
        // finishes at roughly the same time as the minors.
        final slotCounts = <String, int>{for (final d in activeCorners) d: 1};
        final emptyCount = SheetPlan.slotsPerSheet - activeCorners.length;
        for (var e = 0; e < emptyCount; e++) {
          // Pick the design whose current "load" (qty per slot) is highest
          // — adding another slot to it pulls its finish time closer to
          // the rest.
          String pick = activeCorners.first;
          var pickLoad = -1.0;
          for (final d in activeCorners) {
            final load = remaining[d]! / slotCounts[d]!;
            if (load > pickLoad) {
              pickLoad = load;
              pick = d;
            }
          }
          slotCounts[pick] = slotCounts[pick]! + 1;
        }

        // Build the slot template — each design's home corner first, then
        // fill the rest in row-major order until each design has its
        // assigned slot count.
        final template = List<String?>.filled(SheetPlan.slotsPerSheet, null);
        for (final d in activeCorners) {
          template[homeCorner[d]!] = d;
        }
        for (var i = 0; i < SheetPlan.slotsPerSheet; i++) {
          if (template[i] != null) continue;
          // First active design that still needs another slot.
          for (final d in activeCorners) {
            final currentCount = template.where((x) => x == d).length;
            if (currentCount < slotCounts[d]!) {
              template[i] = d;
              break;
            }
          }
          // If somehow nothing fit (every design already at its quota),
          // fall back to the dominant.
          template[i] ??= activeCorners.first;
        }

        // copies = floor(min(qty[d] / slotCounts[d])) — but never below 1
        // if there's any work to do, otherwise we'd loop forever on the
        // 1-each-of-2-designs edge case.
        var minCopies = double.infinity;
        for (final d in activeCorners) {
          final c = remaining[d]! / slotCounts[d]!;
          if (c < minCopies) minCopies = c;
        }
        var copies = minCopies.floor();
        if (copies < 1) copies = 1;

        final slots = template.cast<String>();
        rawSheets.add(SheetPlan(slots: slots, copies: copies));
        for (final d in activeCorners) {
          final after = remaining[d]! - slotCounts[d]! * copies;
          remaining[d] = after < 0 ? 0 : after;
        }
      } else {
        // Phase C — exactly 1 distinct design left. Tail.
        break;
      }
    }

    // Phase C — single-design tail.
    final tail = remaining.entries.where((e) => e.value > 0).toList();
    if (tail.length == 1) {
      final d = tail.first.key;
      final qty = tail.first.value;
      final sheets =
          (qty + SheetPlan.slotsPerSheet - 1) ~/ SheetPlan.slotsPerSheet;
      final slots = List<String>.filled(SheetPlan.slotsPerSheet, d);
      rawSheets.add(SheetPlan(slots: slots, copies: sheets));
    } else if (tail.length > 1) {
      // Shouldn't reach here normally — Phase B handles 2-3 active. Safe
      // fallback: chunk remaining prints across single-design sheets,
      // padded with extras of the dominant.
      final totalLeft = tail.fold<int>(0, (a, b) => a + b.value);
      final sheetsNeeded =
          (totalLeft + SheetPlan.slotsPerSheet - 1) ~/ SheetPlan.slotsPerSheet;
      final emptySlots =
          sheetsNeeded * SheetPlan.slotsPerSheet - totalLeft;
      if (emptySlots > 0) {
        final fillerId = _highestQuantityDesign(requested);
        remaining[fillerId] = (remaining[fillerId] ?? 0) + emptySlots;
      }
      final flat = <String>[];
      final ordered = remaining.entries.where((e) => e.value > 0).toList()
        ..sort((a, b) {
          final byCount = b.value.compareTo(a.value);
          return byCount != 0 ? byCount : a.key.compareTo(b.key);
        });
      for (final e in ordered) {
        flat.addAll(List.filled(e.value, e.key));
      }
      for (var i = 0; i < flat.length; i += SheetPlan.slotsPerSheet) {
        final tailSlots = flat.sublist(i, i + SheetPlan.slotsPerSheet);
        rawSheets.add(SheetPlan(slots: tailSlots, copies: 1));
      }
    }

    final grouped = _groupIdenticalSheets(rawSheets);

    final produced = <String, int>{};
    for (final sheet in grouped) {
      sheet.composition.forEach((id, count) {
        produced[id] = (produced[id] ?? 0) + count * sheet.copies;
      });
    }

    return PackingResult(
      sheets: grouped,
      requestedByDesign: requested,
      producedByDesign: produced,
    );
  }

  static String _highestQuantityDesign(Map<String, int> requested) {
    final entries = requested.entries.toList()
      ..sort((a, b) {
        final byQty = b.value.compareTo(a.value);
        return byQty != 0 ? byQty : a.key.compareTo(b.key);
      });
    return entries.first.key;
  }

  /// Merge sheets that share the exact same slot composition (order
  /// matters — the collage layout is identical, so they're truly the
  /// same template and can be printed N times instead of as N runs).
  static List<SheetPlan> _groupIdenticalSheets(List<SheetPlan> sheets) {
    final byKey = <String, SheetPlan>{};
    for (final s in sheets) {
      final key = s.slots.join('|');
      final existing = byKey[key];
      byKey[key] = existing == null
          ? s
          : SheetPlan(slots: s.slots, copies: existing.copies + s.copies);
    }
    return byKey.values.toList();
  }
}
