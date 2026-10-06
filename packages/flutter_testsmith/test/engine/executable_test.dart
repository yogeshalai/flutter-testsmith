import 'package:test/test.dart';
import 'package:flutter_testsmith/engine.dart';

void main() {
  group('executableCandidates', () {
    test('on Windows, offers the script extensions after the bare name', () {
      // flutter ships as flutter.bat on Windows, and Process.run will not
      // resolve a bare "flutter" to it. Without this, doctor reports
      // Flutter as missing on a machine where it plainly works.
      expect(
        executableCandidates('flutter', isWindows: true),
        ['flutter', 'flutter.bat', 'flutter.cmd', 'flutter.exe'],
      );
    });

    test('off Windows, the bare name is the only candidate', () {
      expect(executableCandidates('flutter', isWindows: false), ['flutter']);
    });

    test('does not add an extension to a name that already has one', () {
      expect(
        executableCandidates('adb.exe', isWindows: true),
        ['adb.exe'],
      );
      expect(
        executableCandidates('run.bat', isWindows: true),
        ['run.bat'],
      );
    });

    test('leaves an absolute path alone', () {
      // An explicit path is the caller being specific; guessing at
      // extensions would be second-guessing them.
      expect(
        executableCandidates(r'D:\Android\Sdk\platform-tools\adb.exe',
            isWindows: true),
        [r'D:\Android\Sdk\platform-tools\adb.exe'],
      );
    });
  });
}
