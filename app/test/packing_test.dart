import 'package:flutter_test/flutter_test.dart';
import 'package:print_collage_tool/models/order_line.dart';
import 'package:print_collage_tool/services/packing.dart';

void main() {
  group('Packer', () {
    test('empty order produces no sheets', () {
      final result = Packer.pack([]);
      expect(result.sheets, isEmpty);
      expect(result.totalSheetsToPrint, 0);
      expect(result.extras, 0);
    });

    test('user example: 1444 x10 + 1456 x10 = 5 sheets, 0 extras', () {
      final result = Packer.pack([
        const OrderLine(designId: '1444', quantity: 10),
        const OrderLine(designId: '1456', quantity: 10),
      ]);

      expect(result.totalSheetsToPrint, 5);
      expect(result.extras, 0);
      expect(result.producedByDesign['1444'], 10);
      expect(result.producedByDesign['1456'], 10);

      final pure1444 = result.sheets.firstWhere((s) => s.isPure && s.slots.first == '1444');
      expect(pure1444.copies, 2);
      expect(pure1444.filename, '2.jpg');

      final pure1456 = result.sheets.firstWhere((s) => s.isPure && s.slots.first == '1456');
      expect(pure1456.copies, 2);

      final mixed = result.sheets.firstWhere((s) => !s.isPure);
      expect(mixed.copies, 1);
      expect(mixed.composition['1444'], 2);
      expect(mixed.composition['1456'], 2);
      expect(mixed.filename, '1.jpg');
      expect(mixed.descriptiveName, contains('1444'));
      expect(mixed.descriptiveName, contains('1456'));
    });

    test('single design qty 100 = 25 pure sheets, 0 extras', () {
      final result = Packer.pack([const OrderLine(designId: '1444', quantity: 100)]);
      expect(result.sheets.length, 1);
      expect(result.sheets.first.copies, 25);
      expect(result.sheets.first.isPure, isTrue);
      expect(result.extras, 0);
    });

    test('single design qty 50 rounds up to 13 sheets (52 prints, 2 extras)', () {
      final result = Packer.pack([const OrderLine(designId: '1444', quantity: 50)]);
      expect(result.totalSheetsToPrint, 13);
      expect(result.totalPrintsProduced, 52);
      expect(result.extras, 2);
    });

    test('single design qty 5 rounds up to 2 sheets (8 prints, 3 extras)', () {
      final result = Packer.pack([const OrderLine(designId: 'A', quantity: 5)]);
      expect(result.totalSheetsToPrint, 2);
      expect(result.extras, 3);
    });

    test('two designs with leftovers needing fill-up: 1444 x11, 1456 x14', () {
      final result = Packer.pack([
        const OrderLine(designId: '1444', quantity: 11),
        const OrderLine(designId: '1456', quantity: 14),
      ]);

      expect(result.producedByDesign['1444'], 11);
      expect(result.extras, 3);
      expect(result.producedByDesign['1456'], 17);
      expect(result.extrasByDesign['1456'], 3);
    });

    test('alphanumeric design IDs work (1333A)', () {
      final result = Packer.pack([
        const OrderLine(designId: '1333A', quantity: 4),
        const OrderLine(designId: '1333B', quantity: 4),
      ]);
      expect(result.sheets.length, 2);
      expect(result.totalSheetsToPrint, 2);
      expect(result.extras, 0);
      expect(result.sheets.every((s) => s.filename == '1.jpg'), isTrue);
      expect(result.sheets.any((s) => s.descriptiveName.contains('1333A')), isTrue);
      expect(result.sheets.any((s) => s.descriptiveName.contains('1333B')), isTrue);
    });

    test('three designs perfect leftover fit', () {
      final result = Packer.pack([
        const OrderLine(designId: '1444', quantity: 11),
        const OrderLine(designId: '1456', quantity: 13),
        const OrderLine(designId: '1789', quantity: 8),
      ]);
      expect(result.extras, 0);
      expect(result.totalPrintsProduced, 32);
      expect(result.totalSheetsToPrint, 8);
    });

    test('zero-quantity and empty-id lines are ignored', () {
      final result = Packer.pack([
        const OrderLine(designId: '1444', quantity: 4),
        const OrderLine(designId: '', quantity: 5),
        const OrderLine(designId: '1456', quantity: 0),
      ]);
      expect(result.sheets.length, 1);
      expect(result.sheets.first.slots, ['1444', '1444', '1444', '1444']);
    });

    test('duplicate design IDs in order are merged', () {
      final result = Packer.pack([
        const OrderLine(designId: 'A', quantity: 4),
        const OrderLine(designId: 'A', quantity: 4),
      ]);
      expect(result.sheets.length, 1);
      expect(result.sheets.first.copies, 2);
      expect(result.totalPrintsProduced, 8);
    });

    test('every produced sheet has 4 slots', () {
      final result = Packer.pack([
        const OrderLine(designId: 'A', quantity: 7),
        const OrderLine(designId: 'B', quantity: 11),
        const OrderLine(designId: 'C', quantity: 3),
      ]);
      for (final s in result.sheets) {
        expect(s.slots.length, 4);
      }
    });

    test('produced totals always >= requested for each design', () {
      final result = Packer.pack([
        const OrderLine(designId: 'A', quantity: 11),
        const OrderLine(designId: 'B', quantity: 14),
        const OrderLine(designId: 'C', quantity: 7),
      ]);
      for (final id in result.requestedByDesign.keys) {
        expect(result.producedByDesign[id]!, greaterThanOrEqualTo(result.requestedByDesign[id]!),
            reason: 'design $id under-produced');
      }
    });
  });
}
