import 'package:meta/meta.dart';

/// A transformation named in a mapping that this build does not know.
@immutable
class UnknownTransformationException implements Exception {
  const UnknownTransformationException(this.name, this.known);

  final String name;
  final List<String> known;

  @override
  String toString() =>
      'UnknownTransformationException: no transformation named "$name". '
      'Known: ${known.join(', ')}.';
}

/// A transformation could not be applied to the value it was given.
@immutable
class TransformationFailedException implements Exception {
  const TransformationFailedException(this.name, this.value, this.reason);

  final String name;
  final Object? value;
  final String reason;

  @override
  String toString() =>
      'TransformationFailedException: $name could not be applied to '
      '${value.runtimeType} "$value": $reason';
}

/// A parsed `name(arg, arg)` spec.
@immutable
class TransformationSpec {
  const TransformationSpec(this.name, this.arguments);

  final String name;
  final List<String> arguments;

  static TransformationSpec parse(String spec) {
    final match = RegExp(r'^(\w+)(?:\(([^)]*)\))?$').firstMatch(spec.trim());
    if (match == null) {
      throw FormatException('Not a transformation spec: "$spec"', spec);
    }
    final rawArgs = match.group(2);
    return TransformationSpec(
      match.group(1)!,
      rawArgs == null || rawArgs.trim().isEmpty
          ? const []
          : [for (final a in rawArgs.split(',')) a.trim()],
    );
  }

  @override
  String toString() =>
      arguments.isEmpty ? name : '$name(${arguments.join(', ')})';
}

typedef TransformationFn = Object? Function(
  Object? value,
  List<String> arguments,
);

/// The named, pure functions a mapping may apply.
///
/// A transformation models what the application *should* do to an API
/// value before displaying it. When the transformation and the
/// application disagree, that disagreement is the finding - which is the
/// whole point of API-to-UI validation.
class TransformationRegistry {
  TransformationRegistry(this._functions);

  factory TransformationRegistry.defaults() => TransformationRegistry({
        'identity': (value, _) => value,
        'toText': (value, _) => value?.toString(),
        'currency': _currency,
        'percent': _percent,
        'negate': _negate,
        'truncate': _truncate,
      });

  final Map<String, TransformationFn> _functions;

  List<String> get names => _functions.keys.toList()..sort();

  TransformationSpec resolve(String spec) {
    final parsed = TransformationSpec.parse(spec);
    if (!_functions.containsKey(parsed.name)) {
      throw UnknownTransformationException(parsed.name, names);
    }
    return parsed;
  }

  /// Applies [spec] to [value].
  ///
  /// A null value passes through untransformed: absent data is a
  /// separate finding from wrongly formatted data, and formatting a null
  /// would blur the two.
  Object? apply(String spec, Object? value) {
    final parsed = resolve(spec);
    if (value == null) return null;
    return _functions[parsed.name]!(value, parsed.arguments);
  }

  static Object? _currency(Object? value, List<String> arguments) {
    if (value is! num) {
      throw TransformationFailedException(
        'currency',
        value,
        'expects a number',
      );
    }
    final code = arguments.isEmpty ? 'INR' : arguments.first;
    final symbol = switch (code) {
      'INR' => 'Rs ',
      'USD' => r'$',
      'EUR' => '€',
      'GBP' => '£',
      _ => '$code ',
    };
    return '$symbol${_groupThousands(value.round())}';
  }

  static Object? _percent(Object? value, List<String> arguments) {
    if (value is! num) {
      throw TransformationFailedException('percent', value, 'expects a number');
    }
    return '${value % 1 == 0 ? value.toInt() : value}% off';
  }

  static Object? _negate(Object? value, List<String> arguments) {
    if (value is! bool) {
      throw TransformationFailedException('negate', value, 'expects a bool');
    }
    return !value;
  }

  static Object? _truncate(Object? value, List<String> arguments) {
    final limit = int.tryParse(arguments.isEmpty ? '' : arguments.first);
    if (limit == null) {
      throw TransformationFailedException(
        'truncate',
        value,
        'needs a length, as truncate(40)',
      );
    }
    final text = value.toString();
    return text.length <= limit ? text : text.substring(0, limit);
  }

  static String _groupThousands(int value) {
    final digits = value.abs().toString();
    final buffer = StringBuffer(value < 0 ? '-' : '');
    for (var i = 0; i < digits.length; i++) {
      if (i > 0 && (digits.length - i) % 3 == 0) buffer.write(',');
      buffer.write(digits[i]);
    }
    return buffer.toString();
  }
}
