import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:speeddial_app/src/state/settings_store.dart';

void main() {
  group('SettingsStore', () {
    test('rail tab survives a new store and ignores unknown values', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        SettingsStore.leftRailTabStorageKey: 'removed-tab',
      });
      final SettingsStore store = SettingsStore();
      final SettingsStore restored = SettingsStore();
      addTearDown(store.dispose);
      addTearDown(restored.dispose);
      await store.init();
      expect(store.leftRailTab, LeftRailTab.sessions);
      int notifications = 0;
      store.addListener(() => notifications++);
      await store.setLeftRailTab(LeftRailTab.inbox);
      await store.setLeftRailTab(LeftRailTab.inbox);
      expect(notifications, 1);
      await restored.init();
      expect(restored.leftRailTab, LeftRailTab.inbox);
    });

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

      await store.rememberNewSessionDefaults(
        'project-a',
        providerId: 'omp',
        yolo: false,
        shortPrompt: false,
      );
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      expect(prefs.getString(SettingsStore.providerStorageKey), 'omp');
    });

    test('a project keeps its own choices and others use the last used '
        'ones', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final SettingsStore store = SettingsStore();
      addTearDown(store.dispose);

      await store.rememberNewSessionDefaults(
        'project-a',
        providerId: 'ante',
        yolo: true,
        shortPrompt: true,
      );
      await store.rememberNewSessionDefaults(
        'project-b',
        providerId: 'claude',
        yolo: false,
        shortPrompt: false,
      );

      final NewSessionDefaults a = store.newSessionDefaultsFor('project-a');
      expect(a.providerId, 'ante');
      expect(a.yolo, isTrue);
      expect(a.shortPrompt, isTrue);

      final NewSessionDefaults fresh = store.newSessionDefaultsFor('project-c');
      expect(fresh.providerId, 'claude');
      expect(fresh.yolo, isFalse);
      expect(fresh.shortPrompt, isFalse);
    });

    test('project and last used choices survive a relaunch', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final SettingsStore store = SettingsStore();
      final SettingsStore restored = SettingsStore();
      addTearDown(store.dispose);
      addTearDown(restored.dispose);

      await store.rememberNewSessionDefaults(
        'project-a',
        providerId: 'ante',
        yolo: true,
        shortPrompt: true,
      );
      await restored.init();

      final NewSessionDefaults a = restored.newSessionDefaultsFor('project-a');
      expect(a.providerId, 'ante');
      expect(a.shortPrompt, isTrue);
      expect(a.yolo, isTrue);

      final NewSessionDefaults fresh = restored.newSessionDefaultsFor(
        'project-b',
      );
      expect(fresh.providerId, 'ante');
      expect(fresh.shortPrompt, isTrue);
      expect(fresh.yolo, isTrue);
    });

    test('remembering unchanged choices does not notify', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final SettingsStore store = SettingsStore();
      addTearDown(store.dispose);
      int notifications = 0;
      store.addListener(() => notifications++);

      for (int i = 0; i < 2; i++) {
        await store.rememberNewSessionDefaults(
          'project-a',
          providerId: 'ante',
          yolo: false,
          shortPrompt: true,
        );
      }

      expect(notifications, 1);
    });

    test(
      'unreadable project memory is reported and does not block startup',
      () async {
        SharedPreferences.setMockInitialValues(<String, Object>{
          SettingsStore.storageKey: 'light',
          SettingsStore.providerStorageKey: 'ante',
          SettingsStore.projectDefaultsStorageKey: 'not json',
        });
        final SettingsStore store = SettingsStore();
        addTearDown(store.dispose);

        await store.init();

        expect(store.themeMode, ThemeMode.light);
        expect(store.lastError, isNotNull);
        expect(store.newSessionDefaultsFor('project-a').providerId, 'ante');
      },
    );

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
