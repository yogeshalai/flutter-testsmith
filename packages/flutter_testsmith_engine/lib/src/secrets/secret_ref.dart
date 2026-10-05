import 'package:meta/meta.dart';

/// What a credential is replaced by wherever one might otherwise print.
///
/// The same literal as the SDK's `RedactionPolicy.marker`, and
/// deliberately not imported from it: `flutter_testsmith_engine` must not depend on
/// `flutter_testsmith`, because the runner must not pull Flutter in, and
/// `scripts/package_boundaries.dart` holds that line. One literal in two
/// packages is the lesser of the two problems.
const String redactionMarker = '[REDACTED]';

/// A secret reference that is not one.
@immutable
class SecretRefFormatException implements Exception {
  const SecretRefFormatException(this.source, this.message);

  final String source;
  final String message;

  @override
  String toString() => 'SecretRefFormatException in $source: $message';
}

/// *Where* a credential lives, never *what* it is.
///
/// This is the half that is allowed to travel: into YAML, into a step
/// description, into a report, onto the console. Keeping the halves in
/// two types is what turns "did we just print the secret?" from a review
/// question into a compiler question.
///
/// Neutral by construction: nothing in this directory knows that
/// authentication, an API token or a Figma token exist. Each of those is
/// a consumer, and the dependency runs one way - `auth/` imports
/// `secrets/`, never the reverse.
@immutable
final class SecretRef {
  const SecretRef({required this.scheme, required this.name});

  /// The only scheme implemented so far. The seam for a second one is
  /// [SecretResolver], not this class - a file or keychain provider is a
  /// new implementation rather than a new design.
  static const String envScheme = 'env';

  final String scheme;
  final String name;

  /// Refuses anything that is not `<scheme>:<name>`.
  ///
  /// A refusal never repeats what it was given. A value that is not a
  /// reference is, as often as not, the credential itself, pasted where
  /// its name belongs - and this check exists to keep literals out of
  /// files, so printing one back onto a console and into CI logs would
  /// undo it. That includes the part before the colon: for a literal
  /// that contains one, it is the front of the credential, and nothing
  /// can tell that apart from a mistyped scheme.
  factory SecretRef.parse(String raw, {required String source}) {
    Never bad(String message) =>
        throw SecretRefFormatException(source, message);

    final separator = raw.indexOf(':');
    if (separator <= 0) {
      bad(
        'the value is not a secret reference. Expected "<scheme>:<name>", '
        'for example "env:MYTEST_AUTH_PIN". A literal credential is never '
        'accepted here, and is not repeated in this message.',
      );
    }

    final scheme = raw.substring(0, separator).trim();
    final name = raw.substring(separator + 1).trim();

    if (scheme != envScheme) {
      bad(
        'unknown secret scheme. Known: $envScheme. What precedes the '
        'colon is not repeated here, because in a literal credential it '
        'would be part of the value.',
      );
    }
    if (name.isEmpty) {
      bad('"$raw" names no variable after "$scheme:".');
    }
    return SecretRef(scheme: scheme, name: name);
  }

  @override
  String toString() => '$scheme:$name';

  @override
  bool operator ==(Object other) =>
      other is SecretRef && other.scheme == scheme && other.name == name;

  @override
  int get hashCode => Object.hash(scheme, name);
}

/// A resolved credential.
///
/// [toString] returns [redactionMarker], so interpolation - the way a
/// secret actually escapes in practice, through an error message
/// somebody added in a hurry - yields the marker rather than the
/// credential. [expose] is the only way out, and every call site of it is
/// a place worth reviewing.
final class Secret {
  const Secret(this._value);

  final String _value;

  String expose() => _value;

  bool get isEmpty => _value.isEmpty;

  @override
  String toString() => redactionMarker;
}

/// A reference that named nothing.
///
/// Carries the reference and nothing else. An exception that helpfully
/// printed the surrounding environment would be the leak this file
/// exists to prevent.
@immutable
class MissingSecretException implements Exception {
  const MissingSecretException(this.ref);

  final SecretRef ref;

  @override
  String toString() =>
      'MissingSecretException: $ref resolved to nothing. Set the ${ref.name} '
      'environment variable, or put it in a .env file that is not committed.';
}

/// Turns a reference into a value.
///
/// Two methods rather than one, and the split is the point. [isPresent]
/// answers "is it there?" and returns a bool, so a run can refuse before
/// it builds anything without the value ever entering the process.
/// [resolve] is called once, immediately before the interaction that
/// needs it, and nothing holds the result afterwards.
abstract interface class SecretResolver {
  bool isPresent(SecretRef ref);

  Secret resolve(SecretRef ref);
}
