import 'package:flutter_test/flutter_test.dart';
import 'package:inventorymgnt/data/models/company.dart';
import 'package:inventorymgnt/data/models/enums.dart';
import 'package:inventorymgnt/data/models/inventory.dart';
import 'package:inventorymgnt/data/models/project.dart';
import 'package:inventorymgnt/data/models/vendor.dart';

void main() {
  group('enum wire mapping', () {
    test('every enum round-trips through its wire value', () {
      for (final role in UserRole.values) {
        expect(UserRole.fromWire(role.wire), role);
      }
      for (final status in ProjectStatus.values) {
        expect(ProjectStatus.fromWire(status.wire), status);
      }
      for (final status in ProjectComponentStatus.values) {
        expect(ProjectComponentStatus.fromWire(status.wire), status);
      }
      for (final vendor in Vendor.values) {
        expect(Vendor.fromWire(vendor.wire), vendor);
      }
      for (final status in CartItemStatus.values) {
        expect(CartItemStatus.fromWire(status.wire), status);
      }
      for (final status in SyncStatus.values) {
        expect(SyncStatus.fromWire(status.wire), status);
      }
    });

    test('transaction reasons use the underscored Postgres spelling', () {
      expect(TransactionReason.manualAdjust.wire, 'manual_adjust');
      expect(TransactionReason.projectDeduction.wire, 'project_deduction');
      expect(
        TransactionReason.fromWire('purchase_received'),
        TransactionReason.purchaseReceived,
      );
    });

    test('cart statuses use the underscored Postgres spelling', () {
      expect(CartItemStatus.addedToCart.wire, 'added_to_cart');
      expect(CartItemStatus.fromWire('added_to_cart'), CartItemStatus.addedToCart);
    });

    test('an unknown wire value falls back rather than throwing', () {
      expect(UserRole.fromWire('superuser'), UserRole.member);
      expect(ProjectStatus.fromWire(null), ProjectStatus.planning);
      expect(Vendor.fromWire('amazon'), Vendor.other);
    });

    test('only pending statuses report as pending', () {
      expect(SyncStatus.synced.isPending, isFalse);
      expect(SyncStatus.pendingCreate.isPending, isTrue);
      expect(SyncStatus.pendingUpdate.isPending, isTrue);
      expect(SyncStatus.pendingDelete.isPending, isTrue);
    });
  });

  group('Component', () {
    test('parses a PostgREST row, including numeric strings', () {
      final component = Component.fromMap({
        'id': 'c-1',
        'inventory_id': 'inv-1',
        'mpn': 'LM358DR',
        'name': 'Dual Op-Amp',
        'manufacturer': 'Texas Instruments',
        'quantity': '24.5',
        'unit': 'pcs',
        'low_stock_threshold': 5,
        'created_at': '2026-01-01T10:00:00Z',
        'updated_at': '2026-01-02T10:00:00Z',
      });

      expect(component.mpn, 'LM358DR');
      expect(component.quantity, 24.5);
      expect(component.lowStockThreshold, 5);
      expect(component.isLowStock, isFalse);
    });

    test('flags low stock at or below the threshold', () {
      Component withQuantity(num quantity, num threshold) => Component(
        id: 'c',
        inventoryId: 'inv',
        mpn: 'X',
        name: 'X',
        quantity: quantity,
        lowStockThreshold: threshold,
        createdAt: DateTime.utc(2026),
        updatedAt: DateTime.utc(2026),
      );

      expect(withQuantity(6, 5).isLowStock, isFalse);
      expect(withQuantity(5, 5).isLowStock, isTrue);
      expect(withQuantity(0, 5).isLowStock, isTrue);
    });

    test('the update payload omits quantity so the guard trigger never fires', () {
      final component = Component(
        id: 'c-1',
        inventoryId: 'inv-1',
        mpn: 'LM358DR',
        name: 'Op-Amp',
        quantity: 42,
        createdAt: DateTime.utc(2026),
        updatedAt: DateTime.utc(2026),
      );

      expect(component.toWriteMap().containsKey('quantity'), isFalse);
    });

    test('the insert payload includes an opening quantity', () {
      final component = Component(
        id: 'c-1',
        inventoryId: 'inv-1',
        mpn: 'LM358DR',
        name: 'Op-Amp',
        quantity: 42,
        createdAt: DateTime.utc(2026),
        updatedAt: DateTime.utc(2026),
      );

      // INSERT is not guarded by the trigger, so opening stock lands in one trip.
      expect(component.toInsertMap('inv-1')['quantity'], 42);
      expect(component.toInsertMap('inv-2')['inventory_id'], 'inv-2');
    });
  });

  group('VendorPrice', () {
    VendorPrice price({num? amount, bool? inStock, Duration age = Duration.zero}) =>
        VendorPrice(
          id: 'p-1',
          componentId: 'c-1',
          vendor: Vendor.robu,
          price: amount,
          inStock: inStock,
          fetchedAt: DateTime.now().toUtc().subtract(age),
          updatedAt: DateTime.now().toUtc(),
        );

    test('a known price with known stock is neither unavailable nor partial', () {
      final p = price(amount: 24.5, inStock: true);
      expect(p.isUnavailable, isFalse);
      expect(p.isPartial, isFalse);
    });

    test('a bot-blocked row is unavailable', () {
      final p = price();
      expect(p.isUnavailable, isTrue);
      expect(p.isBlocked, isTrue);
    });

    test('a price without a stock signal is partial, not unavailable', () {
      final p = price(amount: 24.5);
      expect(p.isUnavailable, isFalse);
      expect(p.isPartial, isTrue);
    });

    test('staleness is measured from fetchedAt', () {
      expect(price(amount: 1, inStock: true).isStale(), isFalse);
      expect(
        price(amount: 1, inStock: true, age: const Duration(hours: 12)).isStale(),
        isTrue,
      );
    });

    test('null stock is not the same as out of stock', () {
      expect(price().inStock, isNull);
      expect(price(inStock: false).inStock, isFalse);
      expect(price().inStock, isNot(false));
    });
  });

  group('ProceedResult', () {
    test('decodes a committed run with deducted lines', () {
      final result = ProceedResult.fromMap({
        'project_id': 'proj-1',
        'committed': true,
        'deducted': [
          {
            'component_id': 'c-1',
            'mpn': 'LM358DR',
            'name': 'Op-Amp',
            'quantity': 4,
            'remaining': 6,
          },
        ],
        'shortfalls': <Object?>[],
      });

      expect(result.committed, isTrue);
      expect(result.hasShortfalls, isFalse);
      expect(result.deducted.single.quantity, 4);
      expect(result.deducted.single.remaining, 6);
    });

    test('decodes a refused run: nothing deducted, shortfalls listed', () {
      final result = ProceedResult.fromMap({
        'project_id': 'proj-1',
        'committed': false,
        'deducted': <Object?>[],
        'shortfalls': [
          {
            'component_id': 'c-2',
            'mpn': 'NE555P',
            'name': 'Timer',
            'required': 10,
            'available': 3,
            'missing': 7,
          },
        ],
      });

      expect(result.committed, isFalse);
      expect(result.hasShortfalls, isTrue);
      expect(result.deducted, isEmpty);
      expect(result.shortfalls.single.missing, 7);
    });
  });

  group('ProjectLine', () {
    ProjectLine line({required num required, required num onHand}) => ProjectLine(
      line: ProjectComponent(
        id: 'pc-1',
        projectId: 'proj-1',
        componentId: 'c-1',
        inventoryId: 'inv-1',
        quantityRequired: required,
        createdAt: DateTime.utc(2026),
        updatedAt: DateTime.utc(2026),
      ),
      component: Component(
        id: 'c-1',
        inventoryId: 'inv-1',
        mpn: 'LM358DR',
        name: 'Op-Amp',
        quantity: onHand,
        createdAt: DateTime.utc(2026),
        updatedAt: DateTime.utc(2026),
      ),
      inventoryName: 'Office',
    );

    test('reports a shortfall against the source inventory', () {
      final l = line(required: 10, onHand: 4);
      expect(l.isShort, isTrue);
      expect(l.missing, 6);
    });

    test('is satisfied when stock covers the requirement exactly', () {
      final l = line(required: 10, onHand: 10);
      expect(l.isShort, isFalse);
      expect(l.missing, 0);
    });

    test('never reports a negative shortfall when overstocked', () {
      final l = line(required: 2, onHand: 50);
      expect(l.isShort, isFalse);
      expect(l.missing, 0);
    });
  });

  group('AppUser', () {
    test('has no company before onboarding', () {
      final user = AppUser.fromMap({
        'id': 'u-1',
        'email': 'a@b.com',
        'company_id': null,
        'role': 'member',
        'created_at': '2026-01-01T00:00:00Z',
      });

      expect(user.hasCompany, isFalse);
      expect(user.role, UserRole.member);
    });

    test('falls back to the email when no display name is set', () {
      final user = AppUser.fromMap({
        'id': 'u-1',
        'email': 'a@b.com',
        'company_id': 'co-1',
        'display_name': '',
        'role': 'owner',
        'created_at': '2026-01-01T00:00:00Z',
      });

      expect(user.hasCompany, isTrue);
      expect(user.label, 'a@b.com');
      expect(user.role, UserRole.owner);
    });
  });
}
