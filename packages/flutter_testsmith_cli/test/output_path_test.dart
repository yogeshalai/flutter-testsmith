// S8: where a command writes, and what a relative path is relative to.
//
// The rule under test is one sentence - a relative output path is
// resolved against the resolved application root, an absolute one is
// left alone - and it is tested here rather than through six commands
// because this is where the rule lives. The command-level coverage in
// output_path_coordinates_test.dart proves the commands reach it.
library;

import 'dart:io';

import 'package:flutter_testsmith_cli/src/output_path.dart';
import 'package:test/test.dart';

void main() {
  final app = Directory('/projects/my_app');

  group('a relative path', () {
    test('is resolved against the application root, not the cwd', () {
      expect(
        resolveOutputPath(app, 'out/results'),
        '/projects/my_app/out/results',
      );
    });

    test('does not change when the process cwd changes', () {
      // The whole point of S8. The function is given no cwd and reads
      // none, so standing somewhere else cannot move the answer.
      final before = resolveOutputPath(app, 'out');
      final previous = Directory.current;
      addTearDown(() => Directory.current = previous);
      Directory.current = Directory.systemTemp;

      expect(resolveOutputPath(app, 'out'), before);
    });

    test('keeps a nested path nested', () {
      expect(
        resolveOutputPath(app, 'out/suite/run-1'),
        '/projects/my_app/out/suite/run-1',
      );
    });

    test('naming the root itself is the root', () {
      expect(resolveOutputPath(app, ''), '/projects/my_app');
    });

    test('does not double a trailing forward slash on the root', () {
      expect(
        resolveOutputPath(Directory('/projects/app/'), 'out'),
        '/projects/app/out',
      );
    });

    test('does not double a trailing backslash on a Windows root', () {
      expect(
        resolveOutputPath(Directory('C:\\projects\\app\\'), 'out',
            windows: true),
        'C:\\projects\\app/out',
      );
    });
  });

  group('an absolute path', () {
    test('is left exactly as written', () {
      expect(resolveOutputPath(app, '/var/reports'), '/var/reports');
    });

    test('is left alone on Windows, drive letter and all', () {
      expect(
        resolveOutputPath(app, 'D:\\reports', windows: true),
        'D:\\reports',
      );
    });

    test('is left alone when it is rooted with a backslash on Windows', () {
      expect(
        resolveOutputPath(app, '\\reports', windows: true),
        '\\reports',
      );
    });

    test('a Windows-looking path is relative on a POSIX host', () {
      // The same rule isAbsolutePath already enforces for project roots:
      // on POSIX, `D:/reports` is a directory called `D:`, and treating
      // it as absolute would write outside the application named.
      expect(
        resolveOutputPath(app, 'D:/reports', windows: false),
        '/projects/my_app/D:/reports',
      );
    });
  });

  group('the typed wrappers', () {
    test('resolveOutputDirectory applies the same rule', () {
      expect(resolveOutputDirectory(app, 'out').path, '/projects/my_app/out');
      expect(resolveOutputDirectory(app, '/var/out').path, '/var/out');
    });

    test('resolveOutputFile applies the same rule', () {
      expect(
        resolveOutputFile(app, 'out/tree.json').path,
        '/projects/my_app/out/tree.json',
      );
      expect(resolveOutputFile(app, '/var/tree.json').path, '/var/tree.json');
    });
  });
}
