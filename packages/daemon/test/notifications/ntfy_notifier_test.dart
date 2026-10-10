import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:speeddial_daemon/src/notifications/ntfy_notifier.dart';
import 'package:speeddial_protocol/speeddial_protocol.dart';
import 'package:test/test.dart';

Session _session({String title = '修正 🔥'}) {
  final DateTime now = DateTime.utc(2026);
  return Session(
    id: 's1',
    projectId: 'p1',
    providerId: 'fake',
    title: title,
    status: SessionStatus.idle,
    model: null,
    cwd: '/tmp/project',
    baseBranch: null,
    yolo: false,
    archived: false,
    createdAt: now,
    updatedAt: now,
  );
}

void main() {
  test('topics require a complete ASCII name within the ntfy limit', () {
    for (final String topic in ['topic', 'a-b_c123', 'x' * 64]) {
      expect(NtfyNotifier.isValidTopic(topic), isTrue);
    }
    for (final String topic in [
      '',
      'topic\n',
      'topic\r',
      'topic/name',
      'あ',
      'x' * 65,
    ]) {
      expect(NtfyNotifier.isValidTopic(topic), isFalse);
    }
  });

  late _FakeHttpClient client;
  late NtfyNotifier notifier;
  setUp(() {
    client = _FakeHttpClient();
    notifier = NtfyNotifier(topic: 'my-topic', httpClientFactory: () => client);
  });

  test(
    'publishes Unicode title, Markdown, completion tag and session action',
    () async {
      await notifier.publish(_session(), '**Done** — fixed it 🔥.');
      expect(client.url, Uri.parse('https://ntfy.sh/'));
      expect(client.request.headers.contentType, ContentType.json);
      expect(client.request.followRedirects, isFalse);
      expect(client.request.contentLength, client.request.bytes.length);
      final Map<String, Object?> payload = client.request.payload;
      expect(payload['topic'], 'my-topic');
      expect(payload['title'], '修正 🔥');
      expect(payload['message'], '**Done** — fixed it 🔥.');
      expect(payload['tags'], ['heavy_check_mark']);
      expect(payload['priority'], 3);
      expect(payload['markdown'], isTrue);
      final SessionLink link = SessionLink.fromUri(
        Uri.parse(payload['click']! as String),
      )!;
      expect(link.sessionId, 's1');
      expect(link.projectId, 'p1');
      expect(payload['actions'], [
        {'action': 'view', 'label': 'Open SpeedDial', 'url': payload['click']},
      ]);
      expect(client.closedForcefully, isTrue);
    },
  );

  test('can link to a hosted web app', () async {
    notifier = NtfyNotifier(
      topic: 'my-topic',
      appUrl: Uri.parse('https://app.example/app/?theme=dark#/'),
      httpClientFactory: () => client,
    );
    await notifier.publish(_session(), 'Done.');
    final Uri link = Uri.parse(client.request.payload['click']! as String);
    expect(link.host, 'app.example');
    expect(link.path, '/app/');
    expect(link.queryParameters, {
      'theme': 'dark',
      'sessionId': 's1',
      'projectId': 'p1',
    });
    expect(link.fragment, '/');
  });

  test('bounds long titles and replies at whole UTF-8 characters', () async {
    await notifier.publish(_session(title: '🔥' * 1000), '🔥あ' * 2000);
    final Map<String, Object?> payload = client.request.payload;
    final String title = payload['title']! as String;
    final String message = payload['message']! as String;
    expect(utf8.encode(title).length, lessThanOrEqualTo(1024));
    expect(utf8.encode(message).length, lessThanOrEqualTo(4096));
    expect(title, endsWith('…'));
    expect(message, endsWith('…'));
    expect(message, isNot(contains('\uFFFD')));
  });

  test('does not contact ntfy for an empty reply', () async {
    await notifier.publish(_session(), ' \n ');
    expect(client.url, isNull);
  });

  test('HTTP rejection is reported and the client is closed', () async {
    client.statusCode = 429;
    await expectLater(
      notifier.publish(_session(), 'Done.'),
      throwsA(
        isA<HttpException>().having(
          (e) => e.message,
          'message',
          contains('429'),
        ),
      ),
    );
    expect(client.closedForcefully, isTrue);
  });

  test('connection failures close the client and propagate', () async {
    client.error = const SocketException('offline');
    await expectLater(
      notifier.publish(_session(), 'Done.'),
      throwsA(isA<SocketException>()),
    );
    expect(client.closedForcefully, isTrue);
  });

  test(
    'the whole exchange has a deadline, including response streaming',
    () async {
      final StreamController<List<int>> stalled = StreamController<List<int>>();
      client.responseBody = stalled.stream;
      notifier = NtfyNotifier(
        topic: 'my-topic',
        timeout: const Duration(milliseconds: 10),
        httpClientFactory: () => client,
      );
      await expectLater(
        notifier.publish(_session(), 'Done.'),
        throwsA(isA<TimeoutException>()),
      );
      expect(client.closedForcefully, isTrue);
      await stalled.close();
    },
  );
}

class _FakeHttpClient implements HttpClient {
  final _FakeHttpRequest request = _FakeHttpRequest();
  Uri? url;
  Object? error;
  int statusCode = 200;
  Stream<List<int>> responseBody = const Stream<List<int>>.empty();
  bool closedForcefully = false;
  @override
  Duration? connectionTimeout;

  @override
  Future<HttpClientRequest> postUrl(Uri url) async {
    this.url = url;
    if (error != null) throw error!;
    request.response = _FakeHttpResponse(statusCode, responseBody);
    return request;
  }

  @override
  void close({bool force = false}) {
    closedForcefully = force;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeHttpRequest implements HttpClientRequest {
  final List<int> bytes = <int>[];
  late HttpClientResponse response;
  @override
  final HttpHeaders headers = _FakeHttpHeaders();
  @override
  bool followRedirects = true;
  @override
  int contentLength = -1;
  Map<String, Object?> get payload =>
      Map<String, Object?>.from(jsonDecode(utf8.decode(bytes)) as Map);
  @override
  void add(List<int> data) => bytes.addAll(data);
  @override
  Future<HttpClientResponse> close() async => response;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeHttpHeaders implements HttpHeaders {
  @override
  ContentType? contentType;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeHttpResponse extends Stream<List<int>>
    implements HttpClientResponse {
  _FakeHttpResponse(this.statusCode, this._body);
  @override
  final int statusCode;
  final Stream<List<int>> _body;
  @override
  StreamSubscription<List<int>> listen(
    void Function(List<int>)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) => _body.listen(
    onData,
    onError: onError,
    onDone: onDone,
    cancelOnError: cancelOnError,
  );
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
