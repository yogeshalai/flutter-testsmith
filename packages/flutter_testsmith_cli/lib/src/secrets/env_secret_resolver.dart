import 'dart:io';

import 'package:flutter_testsmith_engine/flutter_testsmith_engine.dart';

import '../dotenv.dart';

/// Resolves `env:NAME` references from the process environment, then
/// from a `.env` file.
///
/// That precedence is [DotEnv]'s own and is inherited rather than
/// restated: the real environment always wins, so CI - which sets
/// variables properly - is never overridden by a developer's local copy
/// that happened to get committed to a branch.
///
/// [environment] is injectable only so tests need not mutate the real
/// process environment, which Dart cannot do.
class EnvSecretResolver implements SecretResolver {
  EnvSecretResolver({
    DotEnv? dotenv,
    Map<String, String>? environment,
  })  : _dotenv = dotenv ?? const DotEnv.empty(),
        _environment = environment ?? Platform.environment;

  final DotEnv _dotenv;
  final Map<String, String> _environment;

  /// The value, or null. Private, so nothing outside this class can get
  /// a credential as a bare String.
  String? _lookUp(SecretRef ref) => _environment[ref.name] ?? _dotenv[ref.name];

  @override
  bool isPresent(SecretRef ref) => (_lookUp(ref) ?? '').isNotEmpty;

  @override
  Secret resolve(SecretRef ref) {
    final value = _lookUp(ref);
    if (value == null || value.isEmpty) throw MissingSecretException(ref);
    return Secret(value);
  }
}
