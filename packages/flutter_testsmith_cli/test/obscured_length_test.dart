// DEF-E05-06 - a credential's delivery was never actually verified.
//
// `_verifyDelivered` compared the *marker string's* length against the
// secret's length. The SDK renders an obscured field as
// "[REDACTED]:6" - so for a six-character PIN the comparison was 12
// against 6, and where the field reported no text at all the check
// returned quietly and the run read exactly like one that had verified.
//
// The count inside the marker is the signal that was there all along. It
// is a number: reading it proves a credential arrived whole without any
// part of it being read.
import 'package:test/test.dart';
import 'package:flutter_testsmith_cli/src/app_session.dart';
import 'package:flutter_testsmith_engine/flutter_testsmith_engine.dart';

void main() {
  group('the obscured marker is parsed, not measured', () {
    test('a six digit PIN reports six', () {
      // The exact regression: a six-digit PIN in an obscured field.
      expect(AppSession.obscuredLength('$redactionMarker:6'), 6);
    });

    test('the marker string length is not the answer', () {
      // "[REDACTED]:6" is twelve characters. Twelve was the old answer,
      // and it never equalled six.
      const marked = '$redactionMarker:6';
      expect(marked.length, isNot(6));
      expect(AppSession.obscuredLength(marked), 6);
    });

    test('a shorter delivery reports its own smaller count', () {
      expect(AppSession.obscuredLength('$redactionMarker:4'), 4);
    });

    test('a zero count is a count, not an absence', () {
      expect(AppSession.obscuredLength('$redactionMarker:0'), 0);
    });

    test('a long count parses', () {
      expect(AppSession.obscuredLength('$redactionMarker:128'), 128);
    });

    test('plaintext is not a marker', () {
      expect(AppSession.obscuredLength('9000000001'), isNull);
      expect(AppSession.obscuredLength(''), isNull);
      expect(AppSession.obscuredLength('Welcome!'), isNull);
    });

    test('a marker with no count is not a count', () {
      expect(AppSession.obscuredLength(redactionMarker), isNull);
      expect(AppSession.obscuredLength('$redactionMarker:'), isNull);
    });

    test('a marker with a non-numeric tail is refused, not guessed', () {
      expect(AppSession.obscuredLength('$redactionMarker:6a'), isNull);
      expect(AppSession.obscuredLength('$redactionMarker:six'), isNull);
    });

    test('the documented spelling is not the emitted one', () {
      // The application's own comment calls this "[REDACTED:n]". The SDK
      // emits "[REDACTED]:n". Parsing the documented spelling would
      // match nothing, silently, which is the class of bug this whole
      // defect belongs to.
      expect(AppSession.obscuredLength('[REDACTED:6]'), isNull);
      expect(AppSession.obscuredLength('$redactionMarker:6'), 6);
    });

    test('the marker never carries the characters it stands for', () {
      const marked = '$redactionMarker:6';
      expect(marked, isNot(contains('1')));
      expect(marked, isNot(contains('9')));
      // Only the count and the marker itself.
      expect(marked, '[REDACTED]:6');
    });
  });
}
