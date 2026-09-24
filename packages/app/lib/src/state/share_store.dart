import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:speeddial_protocol/speeddial_protocol.dart';

import '../scope.dart';
import 'sessions_store.dart';

/// Android's share payload is held in memory until the user stages or cancels
/// it. Only project labels and session creation settings go to preferences.
class ShareStore extends ChangeNotifier {
  ShareStore(this.data);

  static const String storageKey = 'speeddial.shareTargets.v1';
  static const String channelName = 'sh.speeddial/share';

  final AppData data;
  final MethodChannel _channel = const MethodChannel(channelName);
  final Map<String, ShareTarget> _targets = <String, ShareTarget>{};
  final Map<String, ShareSettings> _settings = <String, ShareSettings>{};
  final Map<String, List<OutgoingAttachment>> _staged =
      <String, List<OutgoingAttachment>>{};
  OutgoingAttachment? _pending;
  OutgoingAttachment? _creatingFile;
  final Set<OutgoingAttachment> _cancelledFiles = <OutgoingAttachment>{};
  String? _error;
  bool _creating = false;
  bool _started = false;
  String _lastSaved = '';
  Future<bool>? _persisting;

  OutgoingAttachment? get pending => _pending;
  String? get error => _error;
  bool get creating => _creating;
  List<ShareTarget> get targets =>
      List<ShareTarget>.unmodifiable(_targets.values);

  static String targetId(String daemonId, String projectId) =>
      'project:${base64Url.encode(utf8.encode(daemonId))}:'
      '${base64Url.encode(utf8.encode(projectId))}';

  String _sessionKey(String daemonId, String sessionId) =>
      '$daemonId\u0000$sessionId';

  List<OutgoingAttachment> stagedFor(String daemonId, String sessionId) =>
      List<OutgoingAttachment>.unmodifiable(
        _staged[_sessionKey(daemonId, sessionId)] ??
            const <OutgoingAttachment>[],
      );

  void attachTo(String daemonId, String sessionId) {
    final OutgoingAttachment? file = _pending;
    if (file == null) return;
    _stage(file, daemonId, sessionId);
  }

  void _stage(OutgoingAttachment file, String daemonId, String sessionId) {
    final List<OutgoingAttachment> staged = _staged.putIfAbsent(
      _sessionKey(daemonId, sessionId),
      () => <OutgoingAttachment>[],
    );
    if (staged.length >= kMaxAttachmentsPerMessage) {
      _error =
          'This session already has $kMaxAttachmentsPerMessage shared files';
      notifyListeners();
      return;
    }
    staged.add(file);
    if (identical(_pending, file)) _pending = null;
    _error = null;
    notifyListeners();
  }

  void removeStaged(
    String daemonId,
    String sessionId,
    Iterable<OutgoingAttachment> files,
  ) {
    final String key = _sessionKey(daemonId, sessionId);
    final List<OutgoingAttachment>? staged = _staged[key];
    if (staged == null) return;
    bool changed = false;
    for (final OutgoingAttachment file in files) {
      changed = staged.remove(file) || changed;
    }
    if (staged.isEmpty) _staged.remove(key);
    if (changed) notifyListeners();
  }

  void cancel() {
    if (_creatingFile != null) _cancelledFiles.add(_creatingFile!);
    _pending = null;
    _error = null;
    notifyListeners();
  }

  Future<void> init() async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    final String? raw = prefs.getString(storageKey);
    if (raw != null) {
      try {
        final Map<String, Object?> decoded = (jsonDecode(raw) as Map)
            .cast<String, Object?>();
        for (final Object? item in decoded['targets'] as List? ?? const []) {
          final ShareTarget target = ShareTarget.fromJson(
            (item as Map).cast<String, Object?>(),
          );
          _targets[target.id] = target;
        }
        for (final Object? item in decoded['settings'] as List? ?? const []) {
          final ShareSettings setting = ShareSettings.fromJson(
            (item as Map).cast<String, Object?>(),
          );
          _settings[setting.targetId] = setting;
        }
      } on Object {
        _targets.clear();
        _settings.clear();
      }
    }
    _lastSaved = _encodedCache();
    data.projects.addListener(_syncProjects);
    data.sessions.addListener(_syncSessions);
    data.connections.addListener(_syncProjects);
    _syncProjects();
    _syncSessions();
  }

  Future<void> startAndroid() async {
    if (_started) return;
    _started = true;
    _channel.setMethodCallHandler((MethodCall call) async {
      if (call.method != 'incoming') return;
      await receive((call.arguments as Map).cast<String, Object?>());
    });
    await _publishTargets();
    try {
      final Map<Object?, Object?>? initial = await _channel
          .invokeMapMethod<Object?, Object?>('takeInitial');
      if (initial != null) {
        await receive(initial.cast<String, Object?>());
      }
    } on MissingPluginException {
      // Non-Android test or embedder.
    }
  }

  Future<void> receive(Map<String, Object?> payload) async {
    final String? failure = payload['error'] as String?;
    if (failure != null) {
      _pending = null;
      _error = failure;
      notifyListeners();
      return;
    }
    final String name = payload['name'] as String? ?? 'shared-file';
    final String mimeType =
        payload['mimeType'] as String? ?? mimeTypeForFileName(name);
    final String? bytes = payload['data'] as String?;
    if (bytes == null) return;
    _pending = OutgoingAttachment(name: name, mimeType: mimeType, data: bytes);
    _error = null;
    notifyListeners();
    final String? shortcutId = payload['shortcutId'] as String?;
    if (shortcutId == null || shortcutId.isEmpty) return;
    final ShareTarget? target = _targets[shortcutId];
    if (target == null ||
        !data.connections.endpoints.any(
          (DaemonEndpoint endpoint) => endpoint.id == target.daemonId,
        )) {
      _error = 'This project share target is no longer available';
      notifyListeners();
      return;
    }
    await _createForTarget(target, _pending!);
  }

  Future<void> _createForTarget(
    ShareTarget target,
    OutgoingAttachment file,
  ) async {
    if (_creating) return;
    _creating = true;
    _creatingFile = file;
    notifyListeners();
    try {
      ShareSettings? saved = _settings[target.id];
      if (saved == null) {
        await data.daemonConfig.refreshInfo(target.daemonId);
        final List<ProviderInfo> providers =
            data.daemonConfig.infoFor(target.daemonId)?.providers ??
            const <ProviderInfo>[];
        final ProviderInfo provider = providers.firstWhere(
          (ProviderInfo p) => p.id == data.settings.providerId && p.available,
          orElse: () => providers.firstWhere((ProviderInfo p) => p.available),
        );
        await data.git.refresh(target.daemonId, target.projectId);
        final List<Branch> branches =
            data.git.branchesFor(target.projectId) ?? const <Branch>[];
        final String? baseBranch = branches.isEmpty
            ? null
            : branches
                  .firstWhere(
                    (Branch branch) => branch.isCurrent,
                    orElse: () => branches.first,
                  )
                  .name;
        saved = ShareSettings(
          targetId: target.id,
          providerId: provider.id,
          model: null,
          baseBranch: baseBranch,
          sandboxMode:
              provider.sandboxModes.contains(SessionSandboxMode.unrestricted)
              ? SessionSandboxMode.unrestricted
              : null,
          yolo: data.newSessionYolo,
          shortPrompt: data.newSessionShortPrompt,
          mode: SessionMode.build,
          usedAt: DateTime.now().toUtc(),
        );
      }
      String? model = saved.model;
      if (saved.providerId == 'ante' && model != null && !model.contains('/')) {
        await data.daemonConfig.refreshInfo(target.daemonId);
        final List<String> models =
            data.daemonConfig
                .infoFor(target.daemonId)
                ?.providers
                .where((ProviderInfo p) => p.id == 'ante')
                .expand((ProviderInfo p) => p.models)
                .toList() ??
            const <String>[];
        for (final String candidate in models) {
          if (candidate.endsWith('/$model')) {
            model = candidate;
            break;
          }
        }
      }
      final Session session = await data.sessions.create(
        target.daemonId,
        projectId: target.projectId,
        providerId: saved.providerId,
        model: model,
        baseBranch: saved.baseBranch,
        sandboxMode: saved.sandboxMode,
        yolo: saved.yolo,
        shortPrompt: saved.shortPrompt,
        mode: saved.mode,
      );
      if (!_cancelledFiles.contains(file)) {
        _stage(file, target.daemonId, session.id);
        data.selection.selectedDaemonId = target.daemonId;
        data.selection.selectedProjectId = target.projectId;
        data.selection.selectedSessionId = session.id;
      }
    } on Object catch (error) {
      _error = error is DaemonError
          ? error.message
          : 'Could not create session: $error';
      notifyListeners();
    } finally {
      _cancelledFiles.remove(file);
      _creatingFile = null;
      _creating = false;
      notifyListeners();
    }
  }

  void rememberSession(
    String daemonId,
    Session session, {
    String? creationModel,
  }) {
    final String id = targetId(daemonId, session.projectId);
    _settings[id] = ShareSettings.fromSession(
      id,
      session,
      model: creationModel ?? session.model,
      usedAt: DateTime.now().toUtc(),
    );
    unawaited(_persist());
  }

  void _syncProjects() {
    final Set<String> known = <String>{};
    bool changed = false;
    for (final DaemonEndpoint endpoint in data.connections.endpoints) {
      final List<Project> projects = data.projects.projectsFor(endpoint.id);
      for (final Project project in projects) {
        final String id = targetId(endpoint.id, project.id);
        known.add(id);
        final ShareTarget target = ShareTarget(
          id: id,
          daemonId: endpoint.id,
          projectId: project.id,
          label: '${project.name} · ${endpoint.name}',
          lastActiveAt: project.lastActiveAt,
        );
        if (_targets[id]?.label != target.label ||
            _targets[id]?.lastActiveAt != target.lastActiveAt) {
          _targets[id] = target;
          changed = true;
        }
      }
    }
    // An empty project listing may mean the daemon is still loading. Keep
    // cached targets until a successful list arrives; removed endpoints are
    // always removed immediately.
    final Set<String> endpointIds = <String>{
      for (final DaemonEndpoint endpoint in data.connections.endpoints)
        endpoint.id,
    };
    final int before = _targets.length;
    _targets.removeWhere(
      (String _, ShareTarget target) =>
          !endpointIds.contains(target.daemonId) ||
          (data.projects.hasLoaded(target.daemonId) &&
              !known.contains(target.id)),
    );
    changed |= before != _targets.length;
    if (changed) {
      notifyListeners();
      unawaited(_persist());
      unawaited(_publishTargets());
    }
  }

  void _syncSessions() {
    bool changed = false;
    for (final RecentSession recent in data.sessions.recentSessions()) {
      final String id = targetId(recent.daemonId, recent.session.projectId);
      final ShareSettings? old = _settings[id];
      if (old == null || recent.session.updatedAt.isAfter(old.usedAt)) {
        final String? oldModel = old?.model;
        final String? model =
            old?.providerId == recent.session.providerId &&
                oldModel != null &&
                oldModel.contains('/') &&
                recent.session.model != null
            ? '${oldModel.substring(0, oldModel.indexOf('/'))}/${recent.session.model}'
            : recent.session.model;
        _settings[id] = ShareSettings.fromSession(
          id,
          recent.session,
          model: model,
        );
        changed = true;
      }
    }
    if (changed) unawaited(_persist());
  }

  String _encodedCache() => jsonEncode(<String, Object?>{
    'targets': <Object?>[
      for (final ShareTarget target in _targets.values) target.toJson(),
    ],
    'settings': <Object?>[
      for (final ShareSettings setting in _settings.values) setting.toJson(),
    ],
  });

  Future<void> _persist() async {
    final Future<bool>? inFlight = _persisting;
    if (inFlight != null) {
      if (await inFlight && _encodedCache() != _lastSaved) await _persist();
      return;
    }
    final String encoded = _encodedCache();
    if (encoded == _lastSaved) return;
    final Future<bool> write = _writeCache(encoded);
    _persisting = write;
    final bool saved = await write;
    _persisting = null;
    if (saved && _encodedCache() != _lastSaved) await _persist();
  }

  Future<bool> _writeCache(String encoded) async {
    try {
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      await prefs.setString(storageKey, encoded);
      _lastSaved = encoded;
      return true;
    } on Object catch (error) {
      _error = 'Could not save share targets: $error';
      notifyListeners();
      return false;
    }
  }

  Future<void> _publishTargets() async {
    if (!_started) return;
    try {
      final List<ShareTarget> ranked = _targets.values.toList()
        ..sort((ShareTarget a, ShareTarget b) {
          final int activity = b.lastActiveAt.compareTo(a.lastActiveAt);
          return activity != 0 ? activity : a.id.compareTo(b.id);
        });
      await _channel.invokeMethod<void>('publishTargets', <String, Object?>{
        'targets': <Object?>[
          for (final ShareTarget target in ranked) target.toJson(),
        ],
      });
    } on MissingPluginException {
      // Non-Android test or embedder.
    } on PlatformException catch (error) {
      _error = 'Could not update Android share targets: ${error.message}';
      notifyListeners();
    }
  }

  @override
  void dispose() {
    data.projects.removeListener(_syncProjects);
    data.sessions.removeListener(_syncSessions);
    data.connections.removeListener(_syncProjects);
    if (_started) _channel.setMethodCallHandler(null);
    super.dispose();
  }
}

class ShareTarget {
  const ShareTarget({
    required this.id,
    required this.daemonId,
    required this.projectId,
    required this.label,
    required this.lastActiveAt,
  });
  final String id;
  final String daemonId;
  final String projectId;
  final String label;
  final DateTime lastActiveAt;

  factory ShareTarget.fromJson(Map<String, Object?> json) => ShareTarget(
    id: json['id']! as String,
    daemonId: json['daemonId']! as String,
    projectId: json['projectId']! as String,
    label: json['label']! as String,
    lastActiveAt:
        DateTime.tryParse(json['lastActiveAt'] as String? ?? '') ??
        DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
  );
  Map<String, Object?> toJson() => <String, Object?>{
    'id': id,
    'daemonId': daemonId,
    'projectId': projectId,
    'label': label,
    'lastActiveAt': lastActiveAt.toUtc().toIso8601String(),
  };
}

class ShareSettings {
  const ShareSettings({
    required this.targetId,
    required this.providerId,
    required this.model,
    required this.baseBranch,
    required this.sandboxMode,
    required this.yolo,
    required this.shortPrompt,
    required this.mode,
    required this.usedAt,
  });
  final String targetId;
  final String providerId;
  final String? model;
  final String? baseBranch;
  final SessionSandboxMode? sandboxMode;
  final bool yolo;
  final bool shortPrompt;
  final SessionMode mode;
  final DateTime usedAt;

  factory ShareSettings.fromSession(
    String targetId,
    Session session, {
    String? model,
    DateTime? usedAt,
  }) => ShareSettings(
    targetId: targetId,
    providerId: session.providerId,
    model: model ?? session.model,
    baseBranch: session.baseBranch,
    sandboxMode: session.sandboxMode,
    yolo: session.yolo,
    shortPrompt: session.shortPrompt,
    mode: session.mode,
    usedAt: usedAt ?? session.updatedAt,
  );

  factory ShareSettings.fromJson(Map<String, Object?> json) => ShareSettings(
    targetId: json['targetId']! as String,
    providerId: json['providerId']! as String,
    model: json['model'] as String?,
    baseBranch: json['baseBranch'] as String?,
    sandboxMode: switch (json['sandboxMode']) {
      'workspaceWrite' => SessionSandboxMode.workspaceWrite,
      'unrestricted' => SessionSandboxMode.unrestricted,
      _ => null,
    },
    yolo: json['yolo'] as bool? ?? false,
    shortPrompt: json['shortPrompt'] as bool? ?? false,
    mode: json['mode'] == 'plan' ? SessionMode.plan : SessionMode.build,
    usedAt: DateTime.parse(json['usedAt']! as String),
  );

  Map<String, Object?> toJson() => <String, Object?>{
    'targetId': targetId,
    'providerId': providerId,
    'model': model,
    'baseBranch': baseBranch,
    'sandboxMode': sandboxMode?.name,
    'yolo': yolo,
    'shortPrompt': shortPrompt,
    'mode': mode.name,
    'usedAt': usedAt.toIso8601String(),
  };
}
