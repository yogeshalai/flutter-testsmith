import 'dart:convert';

import 'package:ai_client/ai_client.dart';
import 'package:test/test.dart';

/// Captures what was sent and replies with whatever the test wants.
class _FakeTransport {
  Uri? url;
  Map<String, String>? headers;
  Map<String, Object?>? body;

  int statusCode = 200;
  String responseBody = jsonEncode({
    'model': 'openai/gpt-oss-120b',
    'choices': [
      {
        'message': {'content': '{"ok":true}'},
      },
    ],
    'usage': {'prompt_tokens': 10, 'completion_tokens': 5},
  });

  Future<HttpTextResponse> post(
    Uri url,
    Map<String, String> headers,
    String body,
    Duration timeout,
  ) async {
    this.url = url;
    this.headers = headers;
    this.body = (jsonDecode(body) as Map).cast<String, Object?>();
    return HttpTextResponse(statusCode, responseBody);
  }
}

OpenAiCompatibleClient _client(
  _FakeTransport transport, {
  LlmConfig? config,
  String? apiKey = 'test-key',
}) =>
    OpenAiCompatibleClient(
      config: config ?? LlmConfig.defaults,
      apiKey: apiKey,
      post: transport.post,
    );

void main() {
  group('LlmConfig', () {
    test('defaults to Groq with a model that exists there', () {
      expect(LlmConfig.defaults.provider, 'groq');
      expect(
        LlmConfig.defaults.completionsUrl.toString(),
        'https://api.groq.com/openai/v1/chat/completions',
      );
    });

    test('samples at temperature zero, so two runs tell one story', () {
      expect(LlmConfig.defaults.temperature, 0);
    });

    test('switching provider is a configuration change', () {
      final config = LlmConfig.parse(
        'provider: ollama\nmodel: llama3\n',
        source: 'ai.yaml',
      );

      expect(config.provider, 'ollama');
      expect(config.model, 'llama3');
      expect(config.baseUrl, 'http://127.0.0.1:11434/v1');
      expect(config.apiKeyEnv, 'OLLAMA_API_KEY');
      expect(config.requiresKey, isFalse);
    });

    test('a custom OpenAI-compatible endpoint needs only a baseUrl', () {
      final config = LlmConfig.parse(
        'provider: custom\nmodel: my-model\n'
        'baseUrl: https://llm.internal/v1\napiKeyEnv: INTERNAL_LLM_KEY\n',
        source: 'ai.yaml',
      );

      expect(
        config.completionsUrl.toString(),
        'https://llm.internal/v1/chat/completions',
      );
      expect(config.apiKeyEnv, 'INTERNAL_LLM_KEY');
    });

    test('rejects a key written into the config file', () {
      // The whole point of apiKeyEnv is that this file is committable.
      expect(
        () => LlmConfig.parse('provider: groq\napiKey: sk-secret\n',
            source: 'ai.yaml'),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            allOf(contains('apiKey'), contains('environment')),
          ),
        ),
      );
    });

    test('rejects an unknown provider and lists the known ones', () {
      expect(
        () => LlmConfig.parse('provider: hal9000\n', source: 'ai.yaml'),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            allOf(contains('hal9000'), contains('groq')),
          ),
        ),
      );
    });

    test('rejects an unknown key rather than ignoring it', () {
      expect(
        () => LlmConfig.parse('modle: x\n', source: 'ai.yaml'),
        throwsA(isA<FormatException>()),
      );
    });

    test('never puts a key in its description', () {
      expect(LlmConfig.defaults.toString(), 'groq/openai/gpt-oss-120b');
    });
  });

  group('OpenAiCompatibleClient', () {
    test('sends the configured model, temperature and messages', () async {
      final transport = _FakeTransport();
      await _client(transport).complete(
        const LlmPrompt(system: 'be terse', user: 'why did it fail?'),
      );

      expect(transport.body!['model'], 'openai/gpt-oss-120b');
      expect(transport.body!['temperature'], 0);

      final messages = transport.body!['messages']! as List;
      expect((messages.first as Map)['role'], 'system');
      expect((messages.first as Map)['content'], 'be terse');
      expect((messages.last as Map)['content'], 'why did it fail?');
    });

    test('asks for a JSON object only when told to', () async {
      final transport = _FakeTransport();

      await _client(transport)
          .complete(const LlmPrompt(system: 's', user: 'u'));
      expect(transport.body!.containsKey('response_format'), isFalse);

      await _client(transport).complete(
        const LlmPrompt(system: 's', user: 'u', jsonMode: true),
      );
      expect(transport.body!['response_format'], {'type': 'json_object'});
    });

    test('authorises with a bearer token', () async {
      final transport = _FakeTransport();
      await _client(transport)
          .complete(const LlmPrompt(system: 's', user: 'u'));

      expect(transport.headers!['authorization'], 'Bearer test-key');
    });

    test('returns the content, the answering model and the token cost',
        () async {
      final transport = _FakeTransport();
      final completion = await _client(transport)
          .complete(const LlmPrompt(system: 's', user: 'u'));

      expect(completion.content, '{"ok":true}');
      expect(completion.model, 'openai/gpt-oss-120b');
      expect(completion.promptTokens, 10);
      expect(completion.completionTokens, 5);
    });

    test('reports the model that answered, not the one requested', () async {
      // Providers reroute. A report naming the wrong model is worse
      // than one naming none.
      final transport = _FakeTransport()
        ..responseBody = jsonEncode({
          'model': 'openai/gpt-oss-20b',
          'choices': [
            {
              'message': {'content': 'x'},
            },
          ],
        });

      final completion = await _client(transport)
          .complete(const LlmPrompt(system: 's', user: 'u'));

      expect(completion.model, 'openai/gpt-oss-20b');
    });

    test('surfaces the provider\'s own error message', () async {
      final transport = _FakeTransport()
        ..statusCode = 400
        ..responseBody = jsonEncode({
          'error': {'message': 'model `nope` does not exist'},
        });

      await expectLater(
        _client(transport).complete(const LlmPrompt(system: 's', user: 'u')),
        throwsA(
          isA<LlmException>()
              .having((e) => e.message, 'message', contains('does not exist'))
              .having((e) => e.statusCode, 'statusCode', 400)
              .having((e) => e.retryable, 'retryable', isFalse),
        ),
      );
    });

    test('marks rate limiting and server faults as retryable', () async {
      for (final (code, retryable) in [(429, true), (503, true), (401, false)]) {
        final transport = _FakeTransport()
          ..statusCode = code
          ..responseBody = '{"error":{"message":"x"}}';

        await expectLater(
          _client(transport).complete(const LlmPrompt(system: 's', user: 'u')),
          throwsA(
            isA<LlmException>()
                .having((e) => e.retryable, 'retryable for $code', retryable),
          ),
        );
      }
    });

    test('refuses to start without a key, naming the variable', () {
      expect(
        () => _client(_FakeTransport(), apiKey: null),
        throwsA(
          isA<LlmException>().having(
            (e) => e.message,
            'message',
            allOf(contains('GROQ_API_KEY'), contains('.env')),
          ),
        ),
      );
    });

    test('needs no key for a local provider', () {
      expect(
        () => _client(
          _FakeTransport(),
          config: LlmConfig.forProvider('ollama', model: 'llama3'),
          apiKey: null,
        ),
        returnsNormally,
      );
    });

    test('refuses a provider whose wire shape it does not speak', () {
      // Better a clear refusal than an Anthropic endpoint sent an
      // OpenAI body and blamed for the failure.
      expect(
        () => _client(
          _FakeTransport(),
          config: LlmConfig.forProvider('anthropic', model: 'claude-sonnet-5'),
        ),
        throwsA(
          isA<LlmException>().having(
            (e) => e.message,
            'message',
            contains('anthropic'),
          ),
        ),
      );
    });

    test('a malformed body is an exception, not a crash', () async {
      final transport = _FakeTransport()..responseBody = 'not json at all';

      await expectLater(
        _client(transport).complete(const LlmPrompt(system: 's', user: 'u')),
        throwsA(isA<LlmException>()),
      );
    });

    test('a response with no choices is an exception', () async {
      final transport = _FakeTransport()
        ..responseBody = jsonEncode({'choices': <Object>[]});

      await expectLater(
        _client(transport).complete(const LlmPrompt(system: 's', user: 'u')),
        throwsA(isA<LlmException>()),
      );
    });
  });
}
