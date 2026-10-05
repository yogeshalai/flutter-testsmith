import 'package:meta/meta.dart';

import 'llm_config.dart';

/// The model could not be reached, or did not answer usefully.
///
/// Always recoverable by the caller. Nothing in this platform may fail a
/// test run because a language model was unavailable: the verdicts are
/// already decided before any of this is asked.
@immutable
class LlmException implements Exception {
  const LlmException(this.message, {this.statusCode, this.retryable = false});

  final String message;
  final int? statusCode;
  final bool retryable;

  @override
  String toString() =>
      'LlmException${statusCode == null ? '' : ' ($statusCode)'}: $message';
}

/// What to ask.
@immutable
class LlmPrompt {
  const LlmPrompt({
    required this.system,
    required this.user,
    this.jsonMode = false,
  });

  final String system;
  final String user;

  /// Ask the provider to constrain output to a JSON object.
  ///
  /// A hint, not a guarantee - the caller still parses defensively.
  final bool jsonMode;
}

/// What came back.
@immutable
class LlmCompletion {
  const LlmCompletion({
    required this.content,
    required this.model,
    this.promptTokens = 0,
    this.completionTokens = 0,
    this.latency = Duration.zero,
  });

  final String content;

  /// The model the provider says answered.
  ///
  /// Recorded from the response rather than the request: a provider may
  /// route to a different model than the one asked for, and a report
  /// that names the wrong one is worse than one that names none.
  final String model;

  final int promptTokens;
  final int completionTokens;
  final Duration latency;

  @override
  String toString() => 'LlmCompletion($model, ${content.length} chars, '
      '$promptTokens+$completionTokens tokens, ${latency.inMilliseconds}ms)';
}

/// A chat completion model, whoever provides it.
///
/// Deliberately tiny, and deliberately ignorant of testing. Everything
/// this platform asks a model is a prompt in and text out; keeping the
/// interface at that width is what lets the provider be a configuration
/// value rather than a rewrite.
abstract interface class LlmClient {
  /// Provider and model, safe to print. Never includes a key.
  String get describe;

  LlmConfig get config;

  Future<LlmCompletion> complete(LlmPrompt prompt);

  void close();
}
