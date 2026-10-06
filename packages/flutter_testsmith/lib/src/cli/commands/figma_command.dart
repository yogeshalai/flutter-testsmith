import 'dart:convert';
import 'dart:io';

import 'package:args/args.dart';
import 'package:args/command_runner.dart';
import 'package:flutter_testsmith/figma.dart';
import 'package:flutter_testsmith/engine.dart';

import '../dotenv.dart';
import '../output.dart';
import '../output_path.dart';
import '../project_config.dart';
import '../project_root.dart';
import '../secrets/env_secret_resolver.dart';

/// Fetches a Figma frame and writes a normalised specification.
class FigmaCommand extends Command<int> {
  FigmaCommand() {
    addSubcommand(FigmaPullCommand());
  }

  @override
  String get name => 'figma';

  @override
  String get description => 'Work with Figma designs.';
}

class FigmaPullCommand extends Command<int> {
  FigmaPullCommand() {
    argParser
      ..addOption(
        'url',
        help: 'The Figma frame URL, copied from Figma.',
      )
      ..addOption('file-key', help: 'File key, if not giving a URL.')
      ..addOption('node-id', help: 'Node id, if not giving a URL.')
      ..addOption(
        'screen',
        help: 'The application screen this design describes.',
      )
      ..addOption(
        'out',
        help: 'Directory for the normalised spec. Relative to the '
            'application, and defaulting to its "figma" directory, which '
            'is where a run reads it. An absolute path is taken as '
            'written.',
        defaultsTo: 'figma',
      )
      ..addOption(
        'app',
        help: 'Directory of the Flutter application this design describes. '
            'Defaults to the nearest directory at or above this one with '
            'a pubspec.yaml.',
      )
      ..addOption(
        'mapping',
        help: 'Figma node id to semantic id mapping file.',
      )
      ..addFlag('refresh', help: 'Ignore the cache and re-fetch.')
      ..addFlag(
        'write-mapping-template',
        help: 'Write a starter mapping file listing every candidate node.',
      );
  }

  @override
  String get name => 'pull';

  @override
  String get description =>
      'Fetch a frame and normalise it into a design specification.';

  @override
  Future<int> run() async {
    final output = Output();
    final args = argResults!;

    // Resolved first because the credential below is looked for beside
    // the application, and because it is the cheaper precondition: a
    // command aimed at no application has nothing to fetch a design for.
    final root = resolveProjectRoot(args.option('app'));
    if (!root.isFound) {
      output
        ..line(output.red(root.problem!))
        ..line(output.dim('  ${root.hint}'))
        ..line(output.dim('  Or name the application: --app <dir>.'));
      return 1;
    }

    // The same credential path as `testsmith run`, `suite run`, `auth
    // setup` and `generate`: the process environment first, then the
    // first `.env` found beside the application and then beside the
    // caller. This command used to read `Platform.environment` on its
    // own, so a token living only in `<app>/.env` - where E-06 and the
    // Figma source resolver both tell people to put it, and which
    // `.gitignore` protects - resolved for a run and not for the pull
    // that produced the spec that run reads.
    //
    // Still never a flag. A token in argv lands in shell history and in
    // the process list, and that has not changed.
    final DotEnv dotenv;
    try {
      dotenv = DotEnv.load([root.directory!.path, Directory.current.path]);
    } on FormatException catch (error) {
      // A `.env` that is there and cannot be decoded. Not "FIGMA_TOKEN
      // is not set": the token may be in it. Names the file, never what
      // is in it.
      output.line(output.red(error.message));
      return 1;
    }
    final secrets = EnvSecretResolver(dotenv: dotenv);
    final tokenRef = SecretRef.parse('env:FIGMA_TOKEN', source: 'figma pull');
    if (!secrets.isPresent(tokenRef)) {
      output
        ..line(output.red('FIGMA_TOKEN is not set.'))
        ..line(output.dim(
          '  Create a personal access token in Figma under Settings, then '
          'export it as FIGMA_TOKEN, or put it in a .env file beside your '
          'application - which is gitignored. It is deliberately not '
          'accepted as a flag, which would put it in your shell history.',
        ));
      return 1;
    }

    final FigmaTarget target;
    try {
      target = _resolveTarget(args);
    } on FormatException catch (error) {
      output.line(output.red(error.message));
      return 1;
    }

    // Checked here rather than with `mandatory: true`, which throws an
    // unhandled exception instead of saying what to do.
    final screen = args.option('screen');
    if (screen == null || screen.isEmpty) {
      output
        ..line(output.red('--screen is required.'))
        ..line(output.dim(
          '  It names the application screen this design describes, so a '
          'run can find the right spec. For example: --screen /product/details',
        ));
      return 1;
    }
    // Where a pulled spec lands has to be where a run looks for one:
    // `loadFigmaSpecs` reads `<app>/figma`. Defaulting elsewhere wrote a
    // real design into a directory nothing would ever read, and created
    // that directory in the user's repository to do it.
    //
    // S8 removed the other half of that bug: `--out figma` used to mean
    // the cwd while the default meant the application, so typing the
    // default out explicitly moved the file. One base now, either way -
    // which is why the root is resolved above, before the option is read
    // rather than only when it is absent.
    final outputDirectory =
        resolveOutputDirectory(root.directory!, args.option('out')!);

    // Where a run reads designs from, and the only place it reads them.
    // `--out` moves the spec; it does not and cannot move the reader,
    // which takes no output directory of its own.
    final canonical =
        resolveOutputDirectory(root.directory!, figmaDirectoryName);
    // Absolute first: the two may have been spelled from different
    // bases - a relative `--app` with an absolute `--out` - and only
    // then is comparing them lexically meaningful.
    final writesWhereRunsRead = isSamePath(
      outputDirectory.absolute.path,
      canonical.absolute.path,
    );

    FigmaNodeMapping? mapping;
    final mappingPath = args.option('mapping');
    if (mappingPath != null) {
      final file = File(mappingPath);
      if (!file.existsSync()) {
        output.line(output.red('No such mapping file: $mappingPath'));
        return 1;
      }
      try {
        mapping = FigmaNodeMapping.parse(
          await file.readAsString(),
          source: mappingPath,
        );
      } on FormatException catch (error) {
        output.line(output.red(error.message));
        return 1;
      }
    }

    output.line('› fetching ${target.fileKey}#${target.nodeId}');

    // Resolved immediately before the request and not retained, which is
    // what `resolveFigmaSources` does with the same reference. The value
    // goes into one header and nowhere else - see E-02 §10.
    final token = secrets.resolve(tokenRef);
    final client = FigmaClient(
      token: token.expose(),
      // The canonical directory, never the requested one. A cache of
      // Figma's answers belongs to the project rather than to whichever
      // `--out` was typed: following the flag gave `figma pull` and a
      // declared `figmaSource:` two separate caches of the same node,
      // and put the second one outside the `**/figma/.cache/` that
      // `.gitignore` covers.
      cacheDirectory: Directory('${canonical.path}/.cache'),
    );

    // Fetching and normalising under one guard, because they are one
    // question: did Figma give us a design? Normalisation sat outside
    // it, so a response that arrived but held no frame - the gateway
    // answer a cache can keep serving offline for ever - was an
    // unhandled exception and exit 255 rather than a sentence.
    final FigmaScreenSpec spec;
    try {
      final raw = await client.fetchNode(
        fileKey: target.fileKey,
        nodeId: target.nodeId,
        refresh: args.flag('refresh'),
      );
      spec = const FigmaNormaliser().normalise(
        raw,
        nodeId: target.nodeId,
        screen: screen,
        mapping: mapping,
      );
    } on FigmaException catch (error) {
      output.line(output.red(error.message));
      return 1;
    }

    await outputDirectory.create(recursive: true);
    final specFile = File(
      '${outputDirectory.path}/${_slug(screen)}.json',
    );
    await specFile.writeAsString(
      const JsonEncoder.withIndent('  ').convert(spec.toJson()),
    );

    _report(output, spec, specFile);

    if (args.flag('write-mapping-template')) {
      final templateFile = File(
        '${outputDirectory.path}/${_slug(screen)}.mapping.yaml',
      );
      await templateFile.writeAsString(
        FigmaNodeMapping.template(
          screen,
          [
            for (final element in spec.elements)
              (
                nodeId: element.nodeId,
                name: element.figmaName,
                text: element.text,
              ),
          ],
        ),
      );
      output.line('  wrote ${templateFile.path}');
    }

    if (!writesWhereRunsRead) {
      // Said rather than prevented. Pulling a spec somewhere else to
      // read it, diff it or keep it beside something is a fair thing to
      // want, and the file above is real. What is not fair is letting
      // somebody believe a run will pick it up: nothing copies it, and
      // the design dimension would simply report nothing configured for
      // this screen - which reads exactly like a screen nobody has
      // designed yet.
      output
        ..line()
        ..line(output.yellow(
          'Warning: a run will not find this spec.',
        ))
        ..line(output.dim(
          '  A run reads designs from ${canonical.path} and nowhere else, '
          'and this one was written to ${outputDirectory.path}. Nothing '
          'will copy it there. Re-run without --out, or move the file, if '
          'a run should use it.',
        ));
    }

    return 0;
  }

  FigmaTarget _resolveTarget(ArgResults args) {
    final url = args.option('url');
    if (url != null) return FigmaTarget.parseUrl(url);

    final fileKey = args.option('file-key');
    final nodeId = args.option('node-id');
    if (fileKey == null || nodeId == null) {
      throw const FormatException(
        'Give either --url, or both --file-key and --node-id.',
      );
    }
    return FigmaTarget(
      fileKey: fileKey,
      nodeId: FigmaTarget.normaliseNodeId(nodeId),
    );
  }

  void _report(Output output, FigmaScreenSpec spec, File specFile) {
    final byType = <FigmaElementType, int>{};
    for (final element in spec.elements) {
      byType[element.type] = (byType[element.type] ?? 0) + 1;
    }

    output
      ..line()
      ..line(output.bold('${spec.figmaName}  ${output.dim(spec.nodeId)}'))
      ..line('  screen        ${spec.screen}')
      ..line('  frame         ${spec.width} x ${spec.height}')
      ..line('  elements      ${spec.elements.length} '
          '${output.dim('of ${spec.totalNodesWalked} nodes')}')
      ..line('  by type       ${byType.entries.map((e) => '${e.key.wire}:'
          '${e.value}').join('  ')}')
      ..line('  mapped        ${spec.mapped.length}');

    if (spec.mapped.isEmpty) {
      output.line(output.yellow(
        '  No semantic ids yet. Structural comparison needs a mapping: '
        'run again with --write-mapping-template to get a starting point.',
      ));
    }

    if (spec.unmatchedMappings.isNotEmpty) {
      output.line(output.red(
        '  Mapped nodes not in this frame: '
        '${spec.unmatchedMappings.join(', ')}',
      ));
    }

    output..line()..line('  wrote ${specFile.path}');
  }

  static String _slug(String screen) =>
      screen.replaceAll(RegExp('[^a-zA-Z0-9]+'), '_').replaceAll(
            RegExp('^_|_\$'),
            '',
          );
}
