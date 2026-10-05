import 'package:flutter/widgets.dart';

/// Tier 1: marks a single widget with a stable semantic id.
///
/// A [ValueKey] subclass, so it costs nothing and works on any widget that
/// accepts a key:
///
/// ```dart
/// Text(product.name, key: TestKey('product.name'))
/// ```
///
/// Being a distinct type matters. `Key` equality compares `runtimeType`, so
/// an application's own `ValueKey('product.name')` is *not* equal to
/// `TestKey('product.name')` and will not be mistaken for a test id.
class TestKey extends ValueKey<String> {
  const TestKey(super.value);

  String get id => value;
}

/// Tier 2: marks a subtree with a stable semantic id.
///
/// Use where a key will not do - a widget that consumes its own key, or a
/// group of widgets that should be addressed as one. Costs one extra element
/// in the tree, and survives internal refactoring of the child better than a
/// key on a specific descendant.
class TestId extends StatelessWidget {
  const TestId({required this.id, required this.child, super.key})
      : assert(id != '', 'A test id must not be empty');

  final String id;
  final Widget child;

  @override
  Widget build(BuildContext context) => child;
}

/// The semantic id of the widget at [element], or null if it has none.
///
/// Resolution order is fixed so that an element can never resolve
/// ambiguously: [TestKey], then [TestId], then a `Semantics` identifier.
/// See ADR-0004.
String? resolveTestId(Element element) {
  final widget = element.widget;

  final key = widget.key;
  if (key is TestKey) return key.id;

  if (widget is TestId) return widget.id;

  if (widget is Semantics) {
    final identifier = widget.properties.identifier;
    if (identifier != null && identifier.isNotEmpty) return identifier;
  }

  return null;
}
