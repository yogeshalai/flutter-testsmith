// An adb that answers `devices` with nothing attached.
//
// For a test whose premise is "nothing is plugged in". Without one, the
// CLI it starts resolves the host's real adb - and on a machine with a
// handset attached, a test that asserts it stops at the device gate
// instead woke that handset and started `flutter run` on it. Measured at
// 0c03ab2 with an SM-M127G attached:
//
//   validation_before_device_test   2 controls failed
//   app_identity_test, project_root_test
//                                   passed, while printing
//                                   "waking device RZ8T11QETWM" and
//                                   "launching app"
//
// Named through MYTEST_ADB, which wins over ANDROID_HOME, ANDROID_SDK_ROOT
// and PATH, so the host's own tools are otherwise left as they are.
// Portable per A-3.
import 'dart:io';

/// Writes the adb into [directory] and returns its path.
String noDeviceAdb(Directory directory) {
  directory.createSync(recursive: true);
  if (Platform.isWindows) {
    return (File('${directory.path}/adb.bat')
          ..writeAsStringSync(
            '@echo off\r\n'
            'if "%1"=="devices" (\r\n'
            '  echo List of devices attached\r\n'
            '  exit /b 0\r\n'
            ')\r\n'
            'echo error: no devices/emulators found 1>&2\r\n'
            'exit /b 1\r\n',
          ))
        .path;
  }
  final file = File('${directory.path}/adb')
    ..writeAsStringSync(
      '#!/bin/sh\n'
      'if [ "\$1" = "devices" ]; then\n'
      '  echo "List of devices attached"\n'
      '  exit 0\n'
      'fi\n'
      'echo "error: no devices/emulators found" >&2\n'
      'exit 1\n',
    );
  Process.runSync('chmod', ['+x', file.path]);
  return file.path;
}

/// The environment a "nothing is plugged in" test runs the CLI under:
/// the host's, with adb pointed at [noDeviceAdb] and no credential the
/// developer's own shell happens to export.
Map<String, String> noDeviceEnvironment(Directory scratch) => {
      'MYTEST_ADB': noDeviceAdb(Directory('${scratch.path}/no_device_adb')),
      // Set empty rather than removed: the process environment wins over a
      // .env, and an empty value reads as unset (see EnvSecretResolver).
      'MYTEST_AUTH_PIN': '',
    };
