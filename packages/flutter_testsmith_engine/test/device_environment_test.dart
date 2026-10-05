// Reading what a device already is, as opposed to making it do something.
//
// The two parsers here are the whole of E-04's contact with adb output.
// Both are pure, so what the platform concludes from a device can be
// checked without one - and, in the connectivity case, so that what the
// platform is *allowed to see* can be pinned by a test.
import 'package:test/test.dart';
import 'package:flutter_testsmith_engine/flutter_testsmith_engine.dart';

void main() {
  group('parseRuntimePermissions', () {
    // Trimmed from a real `adb shell dumpsys package` on the SM-M127G.
    const dumpsys = '''
    requested permissions:
      android.permission.INTERNET
      android.permission.ACCESS_FINE_LOCATION
      android.permission.RECORD_AUDIO
    install permissions:
      android.permission.INTERNET: granted=true
    User 0:
      runtime permissions:
        android.permission.POST_NOTIFICATIONS: granted=true, flags=[ USER_SENSITIVE_WHEN_GRANTED|USER_SENSITIVE_WHEN_DENIED]
        android.permission.ACCESS_FINE_LOCATION: granted=false, flags=[ USER_SENSITIVE_WHEN_GRANTED|USER_SENSITIVE_WHEN_DENIED]
        android.permission.CAMERA: granted=false, flags=[ ]
''';

    test('reads each runtime permission and whether it is granted', () {
      final permissions = parseRuntimePermissions(dumpsys);

      expect(permissions['android.permission.POST_NOTIFICATIONS'], isTrue);
      expect(permissions['android.permission.ACCESS_FINE_LOCATION'], isFalse);
      expect(permissions['android.permission.CAMERA'], isFalse);
    });

    test('a permission the application never declared is absent, not false',
        () {
      // The distinction matters: `pm grant` fixes a denied permission and
      // cannot fix one the manifest never requested, so the two must not
      // look alike to the check that offers the remedy.
      final permissions = parseRuntimePermissions(dumpsys);

      expect(
        permissions.containsKey('android.permission.RECORD_AUDIO'),
        isFalse,
      );
    });

    test('empty output yields no permissions rather than throwing', () {
      expect(parseRuntimePermissions(''), isEmpty);
    });

    test('an application-defined permission is read too', () {
      final permissions = parseRuntimePermissions(
        '        com.example.app.DYNAMIC_RECEIVER_PERMISSION: granted=true\n',
      );

      expect(
        permissions['com.example.app.DYNAMIC_RECEIVER_PERMISSION'],
        isTrue,
      );
    });
  });

  group('parseActiveDefaultNetwork', () {
    test('a numbered network is an interface that is up', () {
      expect(
        parseActiveDefaultNetwork('Active default network: 152'),
        NetworkInterfaceState.up,
      );
    });

    test('null is an interface that is down', () {
      expect(
        parseActiveDefaultNetwork('Active default network: null'),
        NetworkInterfaceState.down,
      );
    });

    test('no readable line is unknown, not down', () {
      // A probe that failed has learned nothing about the interface, and
      // turning that into "down" would block a run over a question the
      // runner never got an answer to.
      expect(parseActiveDefaultNetwork(''), NetworkInterfaceState.unknown);
      expect(
        parseActiveDefaultNetwork('error: device offline'),
        NetworkInterfaceState.unknown,
      );
    });

    test('reads only the state, even if more of dumpsys reaches it', () {
      // The probe greps on the device precisely so that `dumpsys
      // connectivity`'s SSID, BSSID, MAC and IP never cross to the host.
      // If somebody widens the probe later, this is the parser that must
      // still refuse to carry any of it - and the redaction test is what
      // catches it reaching a report.
      const withEverythingElse = 'Active default network: 152\n'
          'SSID: "Home_Wifi", BSSID: b4:a7:c6:09:44:79, IP: /192.168.1.5';

      expect(
        parseActiveDefaultNetwork(withEverythingElse),
        NetworkInterfaceState.up,
      );
    });
  });
}
