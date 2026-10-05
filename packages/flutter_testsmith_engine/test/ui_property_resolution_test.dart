import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:flutter_testsmith_engine/flutter_testsmith_engine.dart';
import 'package:flutter_testsmith_protocol/flutter_testsmith_protocol.dart';

/// Reading a property off a node that does not carry it itself.
///
/// The measured problem: on a real application `profile.complete_button`
/// was present and visible, and `.text` resolved to null. The captured
/// subtree says why - there are **two** text-bearing descendants, and one
/// of them is an icon:
///
/// ```
/// TestId #profile.complete_button   text=null  visible=true
///   CompleteProfileButton           text=null
///     InkWell                       text=null  enabled=true
///       GestureDetector             text=null
///         SvgPicture                text=null  visible=false
///         Icon                      text=null
///           RichText                text='U+E491'  <- the icon
///         Text                      text='Complete Your Profile'
///         SvgPicture                text=null
/// ```
///
/// `nav.orders` resolves because its icon is an `SvgPicture`, which
/// renders no text at all. A Flutter `Icon` renders through `RichText`
/// carrying a private-use codepoint, and the platform counted it as
/// user-visible text.

const double _unit = 10;

UiNode node({
  String? id,
  String type = 'Widget',
  String? text,
  bool? enabled,
  String? label,
  bool visible = true,
  int? routeIndex,
  List<UiNode> children = const [],
}) =>
    UiNode(
      testId: id,
      type: type,
      text: text,
      label: label,
      enabled: enabled,
      visible: visible,
      bounds: visible
          ? const LogicalRect(x: 0, y: 0, width: _unit, height: _unit)
          : const LogicalRect(x: 0, y: 0, width: 0, height: 0),
      properties: {'routeIndex': ?routeIndex},
      children: children,
    );

/// A Flutter `Icon`, as the inspector actually captures one.
UiNode icon([String glyph = '\u{E491}']) => node(
      type: 'Icon',
      children: [node(type: 'RichText', text: glyph)],
    );

UiSnapshot externalProfile() {
  for (final candidate in [
    'test/fixtures/external/profile.json',
    'packages/flutter_testsmith_engine/test/fixtures/external/profile.json',
  ]) {
    final file = File(candidate);
    if (file.existsSync()) {
      return UiSnapshot.fromJson(
        (jsonDecode(file.readAsStringSync()) as Map).cast<String, Object?>(),
      );
    }
  }
  fail('cannot find the captured profile tree');
}

String? valueOf(UiNode target, String property) =>
    switch (readPropertyOf(target, property)) {
      PropertyValue(:final value) => value?.toString(),
      PropertyAmbiguous() => null,
    };

void main() {
  group('1. a test id directly on a Text', () {
    test('reads its own text', () {
      final target = node(id: 'profile.display_name', type: 'Text', text: 'Test');

      expect(readPropertyOf(target, 'text'), isA<PropertyValue>());
      expect(valueOf(target, 'text'), 'Test');
    });
  });

  group('2-4. a wrapper around exactly one Text', () {
    for (final wrapper in ['InkWell', 'GestureDetector', 'CompleteProfileButton']) {
      test('$wrapper resolves the text below it', () {
        final target = node(
          id: 'x',
          type: 'TestId',
          children: [
            node(type: wrapper, children: [node(type: 'Text', text: 'Go')]),
          ],
        );

        expect(valueOf(target, 'text'), 'Go');
      });
    }

    test('the real complete_button subtree resolves', () {
      // The exact shape captured from the device, icon and all.
      final target = node(
        id: 'profile.complete_button',
        type: 'TestId',
        children: [
          node(
            type: 'CompleteProfileButton',
            label: 'Complete Your Profile',
            children: [
              node(
                type: 'InkWell',
                enabled: true,
                label: 'Complete Your Profile',
                children: [
                  node(
                    type: 'GestureDetector',
                    children: [
                      node(type: 'SvgPicture', visible: false),
                      icon(),
                      node(type: 'Text', text: 'Complete Your Profile'),
                      node(type: 'SvgPicture'),
                    ],
                  ),
                ],
              ),
            ],
          ),
        ],
      );

      expect(valueOf(target, 'text'), 'Complete Your Profile');
      expect(valueOf(target, 'enabled'), 'true');
    });
  });

  group('5. several genuine texts are ambiguous', () {
    test('reading is an ambiguity, not a guess', () {
      final target = node(
        id: 'card',
        children: [
          node(type: 'Text', text: 'Title'),
          node(type: 'Text', text: 'Subtitle'),
        ],
      );

      final read = readPropertyOf(target, 'text');
      expect(read, isA<PropertyAmbiguous>());
      expect((read as PropertyAmbiguous).candidates,
          containsAll(<String>['Title', 'Subtitle']));
    });

    test('identical texts are not ambiguous', () {
      // A TextField and the EditableText inside it report the same
      // string. One answer, stated twice, is still one answer.
      final target = node(
        id: 'field',
        children: [
          node(
            type: 'TextField',
            text: 'test.user@example.com',
            children: [node(type: 'EditableText', text: 'test.user@example.com')],
          ),
        ],
      );

      expect(valueOf(target, 'text'), 'test.user@example.com');
    });
  });

  group('6. no text below', () {
    test('resolves to null, not an ambiguity', () {
      final target = node(id: 'blank', children: [node(type: 'SvgPicture')]);

      expect(readPropertyOf(target, 'text'), isA<PropertyValue>());
      expect(valueOf(target, 'text'), isNull);
    });

    test('an icon alone is not text', () {
      // The root cause, isolated.
      final target = node(id: 'iconOnly', children: [icon()]);

      expect(valueOf(target, 'text'), isNull);
    });
  });

  group('7. hidden descendants do not count', () {
    test('an invisible Text is ignored', () {
      final target = node(
        id: 'x',
        children: [
          node(type: 'Text', text: 'gone', visible: false),
          node(type: 'Text', text: 'shown'),
        ],
      );

      expect(valueOf(target, 'text'), 'shown');
    });

    test('two texts where one is hidden is not ambiguous', () {
      final target = node(
        id: 'x',
        children: [
          node(type: 'Text', text: 'hidden', visible: false),
          node(type: 'Text', text: 'visible'),
        ],
      );

      expect(readPropertyOf(target, 'text'), isA<PropertyValue>());
    });
  });

  group('8. descendants from a route underneath do not count', () {
    test('a text on a lower route is ignored', () {
      final target = node(
        id: 'x',
        routeIndex: 2,
        children: [
          node(type: 'Text', text: 'from below', routeIndex: 1),
          node(type: 'Text', text: 'current', routeIndex: 2),
        ],
      );

      expect(valueOf(target, 'text'), 'current');
    });

    test('a node with no route index still reads its descendants', () {
      final target = node(
        id: 'x',
        children: [node(type: 'Text', text: 'fine')],
      );

      expect(valueOf(target, 'text'), 'fine');
    });
  });

  group('9 & 10. existing behaviour is untouched', () {
    test('the node own text always wins', () {
      final target = node(
        id: 'x',
        type: 'Text',
        text: 'outer',
        children: [node(type: 'Text', text: 'inner')],
      );

      expect(valueOf(target, 'text'), 'outer');
    });

    test('enabled still reads from an unambiguous descendant', () {
      final target = node(
        id: 'nav.orders',
        children: [
          node(type: 'InkWell', enabled: true, children: [
            node(type: 'Text', text: 'Orders'),
          ]),
        ],
      );

      expect(valueOf(target, 'enabled'), 'true');
    });

    test('enabled disagreement is still not a guess', () {
      final target = node(id: 'x', children: [
        node(enabled: true),
        node(enabled: false),
      ]);

      expect(readPropertyOf(target, 'enabled'), isA<PropertyAmbiguous>());
    });

    test('visible, label, type and bounds are unchanged', () {
      final target = node(
        id: 'x',
        type: 'InkWell',
        label: 'Open',
        children: [node(type: 'Text', text: 'Go')],
      );

      expect(valueOf(target, 'visible'), 'true');
      expect(valueOf(target, 'label'), 'Open');
      expect(valueOf(target, 'type'), 'InkWell');
    });

    test('readProperty still returns a plain value for callers that want one',
        () {
      final target = node(id: 'x', children: [node(type: 'Text', text: 'Go')]);

      expect(readProperty(target, 'text'), 'Go');
    });

    test('readProperty returns null on ambiguity rather than throwing', () {
      final target = node(id: 'x', children: [
        node(type: 'Text', text: 'a'),
        node(type: 'Text', text: 'b'),
      ]);

      expect(readProperty(target, 'text'), isNull);
    });
  });

  group('security: traversal must not surface what capture masked', () {
    test('an obscured field resolves to the marker, never the secret', () {
      // The SDK masks an obscured field at capture. Descendant traversal
      // must not reach around that.
      final target = node(
        id: 'login.password',
        children: [
          node(
            type: 'TextField',
            text: '[REDACTED]:24',
            children: [node(type: 'EditableText', text: '[REDACTED]:24')],
          ),
        ],
      );

      final value = valueOf(target, 'text');
      expect(value, '[REDACTED]:24');
      expect(value, isNot(contains('SEEDED')));
    });

    test('a masked field beside a visible label is ambiguous, not leaky', () {
      final target = node(
        id: 'row',
        children: [
          node(type: 'Text', text: 'Password'),
          node(type: 'TextField', text: '[REDACTED]:24'),
        ],
      );

      final read = readPropertyOf(target, 'text');
      expect(read, isA<PropertyAmbiguous>());
      for (final candidate in (read as PropertyAmbiguous).candidates) {
        expect(candidate, isNot(contains('SEEDED')));
      }
    });
  });

  group('over the tree captured from the external application', () {
    test('complete_button now resolves its label', () {
      final target = externalProfile().find('profile.complete_button')!;

      expect(target.text, isNull, reason: 'the wrapper carries no text');
      expect(valueOf(target, 'text'), 'Complete Your Profile');
    });

    test('display_name is unaffected', () {
      final target = externalProfile().find('profile.display_name')!;

      expect(valueOf(target, 'text'), 'Test');
    });

    test('nav.orders is unaffected', () {
      final target = externalProfile().find('nav.orders')!;

      expect(valueOf(target, 'text'), 'Orders');
      expect(valueOf(target, 'enabled'), 'true');
    });

    test('the tree really does contain icon glyphs, or this proves nothing',
        () {
      var glyphs = 0;
      void walk(UiNode n) {
        final text = n.text;
        if (text != null &&
            text.isNotEmpty &&
            text.runes.every((r) => r >= 0xE000 && r <= 0xF8FF)) {
          glyphs++;
        }
        n.children.forEach(walk);
      }

      walk(externalProfile().root);
      expect(glyphs, greaterThanOrEqualTo(4));
    });
  });
}
