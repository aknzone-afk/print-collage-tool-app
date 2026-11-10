import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:print_collage_tool/screens/order_screen.dart';
import 'package:print_collage_tool/services/design_library.dart';
import 'package:print_collage_tool/services/onedrive_auth.dart';
import 'package:print_collage_tool/services/settings_store.dart';

void main() {
  testWidgets('Order screen renders', (WidgetTester tester) async {
    TestWidgetsFlutterBinding.ensureInitialized();
    SharedPreferencesTestUtil.setMock();
    final settings = await AppSettings.load();
    final library = DesignLibrary(OneDriveAuth());
    await tester.pumpWidget(MaterialApp(
      home: OrderScreen(settings: settings, designLibrary: library),
    ));
    expect(find.text('New Order'), findsOneWidget);
    expect(find.text('Add another design'), findsOneWidget);
  });
}

class SharedPreferencesTestUtil {
  static void setMock() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/shared_preferences'),
      (_) async => <String, Object>{},
    );
  }
}
