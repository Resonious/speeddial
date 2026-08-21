import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:speeddial_protocol/speeddial_protocol.dart';

import 'package:speeddial_app/src/state/settings_store.dart';

void main() {
  group('SettingsStore', () {
    test('loads a persisted theme mode', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        SettingsStore.storageKey: 'light',
      });
      final SettingsStore store = SettingsStore();
      addTearDown(store.dispose);

      await store.init();

      expect(store.themeMode, ThemeMode.light);
      expect(store.lastError, isNull);
    });

    test('keeps the default and ignores an unknown mode', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        SettingsStore.storageKey: 'sepia',
      });
      final SettingsStore store = SettingsStore();
      addTearDown(store.dispose);

      await store.init();

      expect(store.themeMode, ThemeMode.system);
      expect(store.lastError, isNull);
    });

    test('loads and persists the provider preference', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        SettingsStore.providerStorageKey: 'ante',
      });
      final SettingsStore store = SettingsStore();
      addTearDown(store.dispose);

      await store.init();
      expect(store.providerId, 'ante');

      await store.setProviderId('omp');
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      expect(prefs.getString(SettingsStore.providerStorageKey), 'omp');
    });

    test('loads and persists the new-session sandbox preference', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        SettingsStore.sandboxStorageKey: 'unrestricted',
      });
      final SettingsStore store = SettingsStore();
      addTearDown(store.dispose);

      await store.init();
      expect(store.sandboxMode, SessionSandboxMode.unrestricted);

      await store.setSandboxMode(SessionSandboxMode.workspaceWrite);
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      expect(
        prefs.getString(SettingsStore.sandboxStorageKey),
        'workspaceWrite',
      );
    });

    test('persists changes and does not notify for a no-op', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final SettingsStore store = SettingsStore();
      addTearDown(store.dispose);
      int notifications = 0;
      store.addListener(() => notifications++);

      await store.setThemeMode(ThemeMode.dark);
      await store.setThemeMode(ThemeMode.dark);

      expect(store.themeMode, ThemeMode.dark);
      expect(notifications, 1);
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      expect(prefs.getString(SettingsStore.storageKey), 'dark');
    });
  });
}
