import 'package:meta/meta.dart';
import 'package:yaml/yaml.dart';

/// A provider's wire dialect.
///
/// Only two exist in practice for our purposes, and the distinction is
/// real rather than cosmetic: an OpenAI-style provider takes
/// `POST {baseUrl}/chat/completions` with a `messages` array, which
/// Groq, OpenAI, OpenRouter, Together, Fireworks, DeepSeek, xAI, Ollama
/// and LM Studio all accept unchanged. Anthropic and Gemini do not.
enum LlmDialect {
  /// `POST {baseUrl}/chat/completions`.
  openAiChat,

  /// `POST {baseUrl}/messages`, with a separate top-level `system`.
  ///
  /// Declared but not implemented. Named here so selecting it fails
  /// with an explanation instead of silently sending the wrong shape
  /// and reporting the provider as broken.
  anthropicMessages,
}

/// A known provider and what it defaults to.
@immutable
class LlmProvider {
  const LlmProvider({
    required this.name,
    required this.dialect,
    required this.baseUrl,
    required this.apiKeyEnv,
    this.defaultModel,
    this.requiresKey = true,
  });

  final String name;
  final LlmDialect dialect;
  final String baseUrl;

  /// The environment variable holding the key.
  ///
  /// The **name**, never the value. A configuration file that can carry
  /// a secret eventually carries one into version control.
  final String apiKeyEnv;

  final String? defaultModel;
  final bool requiresKey;

  static const Map<String, LlmProvider> known = {
    'groq': LlmProvider(
      name: 'groq',
      dialect: LlmDialect.openAiChat,
      baseUrl: 'https://api.groq.com/openai/v1',
      apiKeyEnv: 'GROQ_API_KEY',
      defaultModel: 'openai/gpt-oss-120b',
    ),
    'openai': LlmProvider(
      name: 'openai',
      dialect: LlmDialect.openAiChat,
      baseUrl: 'https://api.openai.com/v1',
      apiKeyEnv: 'OPENAI_API_KEY',
    ),
    'openrouter': LlmProvider(
      name: 'openrouter',
      dialect: LlmDialect.openAiChat,
      baseUrl: 'https://openrouter.ai/api/v1',
      apiKeyEnv: 'OPENROUTER_API_KEY',
    ),
    'together': LlmProvider(
      name: 'together',
      dialect: LlmDialect.openAiChat,
      baseUrl: 'https://api.together.xyz/v1',
      apiKeyEnv: 'TOGETHER_API_KEY',
    ),
    'ollama': LlmProvider(
      name: 'ollama',
      dialect: LlmDialect.openAiChat,
      baseUrl: 'http://127.0.0.1:11434/v1',
      apiKeyEnv: 'OLLAMA_API_KEY',
      requiresKey: false,
    ),
    'anthropic': LlmProvider(
      name: 'anthropic',
      dialect: LlmDialect.anthropicMessages,
      baseUrl: 'https://api.anthropic.com/v1',
      apiKeyEnv: 'ANTHROPIC_API_KEY',
    ),
    // Anything else that speaks the OpenAI dialect. Requires baseUrl.
    'custom': LlmProvider(
      name: 'custom',
      dialect: LlmDialect.openAiChat,
      baseUrl: '',
      apiKeyEnv: 'LLM_API_KEY',
    ),
  };
}

/// Which model to ask, and how.
///
/// Everything that varies between providers lives here, so switching
/// from Groq to a local Ollama or to OpenAI is a configuration change
/// and not a code change.
@immutable
class LlmConfig {
  const LlmConfig({
    required this.provider,
    required this.model,
    required this.baseUrl,
    required this.apiKeyEnv,
    this.dialect = LlmDialect.openAiChat,
    this.temperature = 0,
    this.maxTokens = 2048,
    this.timeout = const Duration(seconds: 60),
    this.requiresKey = true,
  });

  /// Groq with its largest model, which is what this was developed
  /// against.
  static const LlmConfig defaults = LlmConfig(
    provider: 'groq',
    model: 'openai/gpt-oss-120b',
    baseUrl: 'https://api.groq.com/openai/v1',
    apiKeyEnv: 'GROQ_API_KEY',
  );

  final String provider;
  final String model;
  final String baseUrl;
  final String apiKeyEnv;
  final LlmDialect dialect;

  /// Zero by default.
  ///
  /// The analysis is read as evidence about a build. Two runs over the
  /// same failures should not produce two different stories, so the
  /// sampling temperature starts where variation is lowest.
  final double temperature;

  final int maxTokens;
  final Duration timeout;
  final bool requiresKey;

  Uri get completionsUrl => Uri.parse(
        switch (dialect) {
          LlmDialect.openAiChat => '$baseUrl/chat/completions',
          LlmDialect.anthropicMessages => '$baseUrl/messages',
        },
      );

  LlmConfig copyWith({String? model, String? provider}) {
    if (provider != null && provider != this.provider) {
      return LlmConfig.forProvider(provider, model: model ?? this.model);
    }
    return LlmConfig(
      provider: this.provider,
      model: model ?? this.model,
      baseUrl: baseUrl,
      apiKeyEnv: apiKeyEnv,
      dialect: dialect,
      temperature: temperature,
      maxTokens: maxTokens,
      timeout: timeout,
      requiresKey: requiresKey,
    );
  }

  factory LlmConfig.forProvider(String name, {String? model}) {
    final provider = LlmProvider.known[name];
    if (provider == null) {
      throw FormatException(
        'unknown AI provider "$name". Known: '
        '${(LlmProvider.known.keys.toList()..sort()).join(', ')}.',
      );
    }
    final resolved = model ?? provider.defaultModel;
    if (resolved == null) {
      throw FormatException(
        'provider "$name" has no default model, so "model" must be set',
      );
    }
    return LlmConfig(
      provider: provider.name,
      model: resolved,
      baseUrl: provider.baseUrl,
      apiKeyEnv: provider.apiKeyEnv,
      dialect: provider.dialect,
      requiresKey: provider.requiresKey,
    );
  }

  static const Set<String> _keys = {
    'provider',
    'model',
    'baseUrl',
    'apiKeyEnv',
    'temperature',
    'maxTokens',
    'timeoutSeconds',
  };

  /// Reads an `ai.yaml`. A missing file means [defaults].
  factory LlmConfig.parse(String yamlText, {required String source}) {
    final Object? loaded;
    try {
      loaded = loadYaml(yamlText);
    } on YamlException catch (error) {
      throw FormatException('$source: invalid YAML: ${error.message}');
    }
    if (loaded == null) return defaults;
    if (loaded is! Map) {
      throw FormatException('$source: expected a mapping at the root');
    }

    final raw = loaded.cast<Object?, Object?>().map(
          (key, value) => MapEntry(key.toString(), value),
        );

    // Checked before the unknown-key rule, so someone who writes a
    // secret here is told why it is refused rather than being told
    // they made a typo.
    for (final suspect in const ['apiKey', 'api_key', 'key', 'token']) {
      if (raw.containsKey(suspect)) {
        throw FormatException(
          '$source: "$suspect" is not accepted. Put the key in the '
          'environment and name the variable with "apiKeyEnv" - a '
          'secret in this file is a secret in your repository.',
        );
      }
    }

    for (final key in raw.keys) {
      if (_keys.contains(key)) continue;
      throw FormatException(
        '$source: unknown key "$key". Known: ${_keys.join(', ')}.',
      );
    }

    final base = LlmConfig.forProvider(
      (raw['provider'] ?? defaults.provider).toString(),
      model: raw['model']?.toString(),
    );

    num number(String key, num fallback) {
      final value = raw[key];
      if (value == null) return fallback;
      if (value is! num) {
        throw FormatException('$source: "$key" must be a number');
      }
      if (value < 0) throw FormatException('$source: "$key" cannot be negative');
      return value;
    }

    final baseUrl = (raw['baseUrl'] ?? base.baseUrl).toString();
    if (baseUrl.isEmpty) {
      throw FormatException(
        '$source: provider "${base.provider}" has no default endpoint, so '
        '"baseUrl" is required',
      );
    }

    return LlmConfig(
      provider: base.provider,
      model: base.model,
      baseUrl: baseUrl.endsWith('/')
          ? baseUrl.substring(0, baseUrl.length - 1)
          : baseUrl,
      apiKeyEnv: (raw['apiKeyEnv'] ?? base.apiKeyEnv).toString(),
      dialect: base.dialect,
      requiresKey: base.requiresKey,
      temperature: number('temperature', defaults.temperature).toDouble(),
      maxTokens: number('maxTokens', defaults.maxTokens).toInt(),
      timeout: Duration(
        seconds: number('timeoutSeconds', defaults.timeout.inSeconds).toInt(),
      ),
    );
  }

  /// Safe to print and to put in a report: names, never secrets.
  @override
  String toString() => '$provider/$model';
}
