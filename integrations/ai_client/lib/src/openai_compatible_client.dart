import 'dart:convert';
import 'dart:io';

import 'llm_client.dart';
import 'llm_config.dart';

/// One HTTP POST. Injected so the client is testable without a socket.
typedef HttpPost = Future<HttpTextResponse> Function(
  Uri url,
  Map<String, String> headers,
  String body,
  Duration timeout,
);

/// A status code and a body, which is all this client needs.
class HttpTextResponse {
  const HttpTextResponse(this.statusCode, this.body);

  final int statusCode;
  final String body;
}

/// Talks to any provider that speaks the OpenAI chat-completions shape.
///
/// That is most of them: Groq, OpenAI, OpenRouter, Together, Fireworks,
/// DeepSeek, xAI, Ollama and LM Studio all accept the same request
/// unchanged, differing only in endpoint, key and model name - which is
/// exactly what [LlmConfig] holds. Anthropic and Gemini do not, and are
/// rejected here rather than sent a body they will not understand.
class OpenAiCompatibleClient implements LlmClient {
  OpenAiCompatibleClient({
    required this.config,
    required String? apiKey,
    HttpPost? post,
  })  : _apiKey = apiKey,
        _post = post ?? _defaultPost {
    if (config.dialect != LlmDialect.openAiChat) {
      throw LlmException(
        'provider "${config.provider}" speaks a different API shape '
        '(${config.dialect.name}) and has no client yet. Implement one '
        'against LlmClient rather than pointing this one at it.',
      );
    }
    if (config.requiresKey && (apiKey == null || apiKey.isEmpty)) {
      throw LlmException(
        'no API key: set ${config.apiKeyEnv} in the environment or in '
        '.env. It is deliberately not accepted as a command-line flag, '
        'where it would end up in shell history.',
      );
    }
  }

  @override
  final LlmConfig config;

  final String? _apiKey;
  final HttpPost _post;

  @override
  String get describe => '${config.provider}/${config.model}';

  @override
  Future<LlmCompletion> complete(LlmPrompt prompt) async {
    final watch = Stopwatch()..start();

    final body = jsonEncode({
      'model': config.model,
      'temperature': config.temperature,
      'max_tokens': config.maxTokens,
      if (prompt.jsonMode) 'response_format': {'type': 'json_object'},
      'messages': [
        {'role': 'system', 'content': prompt.system},
        {'role': 'user', 'content': prompt.user},
      ],
    });

    final HttpTextResponse response;
    try {
      response = await _post(
        config.completionsUrl,
        {
          'content-type': 'application/json',
          if (_apiKey != null && _apiKey.isNotEmpty)
            'authorization': 'Bearer $_apiKey',
        },
        body,
        config.timeout,
      );
    } on SocketException catch (error) {
      throw LlmException(
        'could not reach ${config.completionsUrl.host}: ${error.message}',
        retryable: true,
      );
    } on HttpException catch (error) {
      throw LlmException(error.message, retryable: true);
    }

    if (response.statusCode != 200) {
      throw LlmException(
        // The provider's own message is the useful part; a rate limit
        // and a wrong model name are very different problems.
        _errorMessage(response.body),
        statusCode: response.statusCode,
        // 429 and 5xx are worth trying again; 4xx is a configuration
        // mistake that retrying will not fix.
        retryable:
            response.statusCode == 429 || response.statusCode >= 500,
      );
    }

    final Map<String, Object?> decoded;
    try {
      decoded = (jsonDecode(response.body) as Map).cast<String, Object?>();
    } on FormatException catch (error) {
      throw LlmException('the response was not JSON: ${error.message}');
    }

    final choices = decoded['choices'];
    if (choices is! List || choices.isEmpty) {
      throw LlmException('the response carried no choices');
    }

    final message = ((choices.first as Map)['message'] as Map?)
        ?.cast<String, Object?>();
    final content = message?['content'];
    if (content is! String) {
      throw LlmException('the response carried no message content');
    }

    final usage = (decoded['usage'] as Map?)?.cast<String, Object?>();

    return LlmCompletion(
      content: content,
      model: (decoded['model'] ?? config.model).toString(),
      promptTokens: (usage?['prompt_tokens'] as num?)?.toInt() ?? 0,
      completionTokens: (usage?['completion_tokens'] as num?)?.toInt() ?? 0,
      latency: watch.elapsed,
    );
  }

  /// Pulls the provider's message out of an error body.
  static String _errorMessage(String body) {
    try {
      final decoded = jsonDecode(body);
      if (decoded is Map) {
        final error = decoded['error'];
        if (error is Map && error['message'] != null) {
          return error['message'].toString();
        }
        if (error != null) return error.toString();
      }
    } on FormatException {
      // Not JSON. Fall through to the raw body.
    }
    return body.length > 300 ? '${body.substring(0, 300)}...' : body;
  }

  static Future<HttpTextResponse> _defaultPost(
    Uri url,
    Map<String, String> headers,
    String body,
    Duration timeout,
  ) async {
    final client = HttpClient()..connectionTimeout = timeout;
    try {
      final request = await client.postUrl(url);
      headers.forEach(request.headers.set);
      request.write(body);

      final response = await request.close().timeout(timeout);
      final text = await utf8.decoder.bind(response).join();
      return HttpTextResponse(response.statusCode, text);
    } finally {
      client.close();
    }
  }

  @override
  void close() {}
}
