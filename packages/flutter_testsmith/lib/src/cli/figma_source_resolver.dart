import 'dart:io';

import 'package:flutter_testsmith/figma.dart';
import 'package:flutter_testsmith/engine.dart';

/// Resolves every screen's declared `figmaSource:` into a normalised
/// specification.
///
/// Through the **existing** client and its on-disk cache, so two runs of
/// the same test see the same design. Figma rate-limits, and a milestone
/// named for determinism should not make a design able to change between
/// two steps of one run.
///
/// Returns the specs it resolved and, separately, the reason each screen
/// that declared one failed. A failure is surfaced rather than
/// swallowed: a declared design that quietly did not load would make the
/// Figma dimension skip, which reads as "not configured" when it is in
/// fact "configured and broken".
Future<(Map<String, FigmaScreenSpec>, Map<String, String>)>
    resolveFigmaSources({
  required Directory project,
  required Map<String, MappingsFile> mappings,
  required SecretResolver secrets,
  FigmaHttp? http,
}) async {
  final specs = <String, FigmaScreenSpec>{};
  final failures = <String, String>{};

  for (final entry in mappings.entries) {
    final source = entry.value.figmaSource;
    if (source == null) continue;

    final screen = entry.key;

    if (!secrets.isPresent(source.token)) {
      failures[screen] = 'the Figma token ${source.token} resolved to '
          'nothing. Set the ${source.token.name} environment variable, or '
          'put it in a .env file that is not committed.';
      continue;
    }

    final mappingFile = File('${project.path}/${source.mappingPath}');
    if (!mappingFile.existsSync()) {
      failures[screen] = 'the node mapping "${source.mappingPath}" does not '
          'exist. Structural comparison maps by node id, never by layer '
          'name; run `testsmith figma pull --write-mapping-template` to get a '
          'starting point.';
      continue;
    }

    final FigmaTarget target;
    try {
      target = FigmaTarget.parseUrl(source.url);
    } on FormatException catch (error) {
      failures[screen] = error.message;
      continue;
    }

    final FigmaNodeMapping nodeMapping;
    try {
      nodeMapping = FigmaNodeMapping.parse(
        await mappingFile.readAsString(),
        source: mappingFile.path,
      );
    } on FormatException catch (error) {
      failures[screen] = error.message;
      continue;
    }

    // Resolved immediately before the request, and not retained.
    final token = secrets.resolve(source.token);
    final client = FigmaClient(
      token: token.expose(),
      http: http,
      cacheDirectory: Directory('${project.path}/figma/.cache'),
    );

    try {
      final raw = await client.fetchNode(
        fileKey: target.fileKey,
        nodeId: target.nodeId,
      );
      specs[screen] = const FigmaNormaliser().normalise(
        raw,
        nodeId: target.nodeId,
        screen: screen,
        mapping: nodeMapping,
      );
    } on FigmaException catch (error) {
      // The client's own message. It names the file key and the status,
      // and has never echoed the token.
      failures[screen] = error.message;
    }
  }

  return (specs, failures);
}

/// Combines on-disk specs with those a mappings file declares.
///
/// A declared `figmaSource:` **wins** for its screen. A stale
/// `figma/<screen>.json` silently shadowing a URL somebody declared is
/// exactly the quiet wrongness this platform exists to avoid, so which
/// one was used is reported rather than assumed.
Map<String, FigmaScreenSpec> mergeFigmaSpecs({
  required Map<String, FigmaScreenSpec> fromDisk,
  required Map<String, FigmaScreenSpec> fromSource,
  void Function(String)? onNote,
}) {
  final merged = {...fromDisk};
  for (final entry in fromSource.entries) {
    if (fromDisk.containsKey(entry.key)) {
      onNote?.call(
        '  figma: "${entry.key}" uses the declared figmaSource, not the '
        'spec on disk',
      );
    }
    merged[entry.key] = entry.value;
  }
  return merged;
}
