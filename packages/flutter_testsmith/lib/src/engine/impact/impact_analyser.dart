import 'package:meta/meta.dart';

import 'impact_index.dart';

/// Which flows a set of changes makes worth running, and why.
@immutable
class ImpactSelection {
  const ImpactSelection({
    required this.selected,
    required this.skipped,
    required this.isFullSuite,
    required this.reason,
    this.reasons = const {},
  });

  final List<FlowCoverage> selected;
  final List<FlowCoverage> skipped;

  /// Selection could not be narrowed and every flow was chosen.
  final bool isFullSuite;

  /// One line explaining the selection as a whole.
  final String reason;

  /// Per-flow explanation, keyed by flow name.
  final Map<String, String> reasons;

  String reasonFor(String flowName) => reasons[flowName] ?? reason;

  Map<String, Object?> toJson() => {
        'fullSuite': isFullSuite,
        'reason': reason,
        'selected': [
          for (final flow in selected)
            {
              'flow': flow.name,
              'path': flow.path,
              'because': reasonFor(flow.name),
            },
        ],
        'skipped': [for (final flow in skipped) flow.name],
      };
}

/// Chooses which flows to run for a set of changed files.
///
/// Deterministic, and that is a deliberate constraint rather than an
/// omission. This decides what gets *tested*: a wrong answer does not
/// produce a visible failure, it produces a regression nobody looked
/// for. A model may later be asked to **widen** a selection - to
/// propose a flow this missed - but it must never narrow one, because
/// the cost of the two mistakes is not remotely symmetric.
///
/// The governing rule follows from that asymmetry: **a flow is excluded
/// only on positive evidence that every changed file is unrelated to
/// it.** One file the index cannot account for selects everything.
class ImpactAnalyser {
  const ImpactAnalyser(this.index);

  final ImpactIndex index;

  /// Paths that cannot change how the application behaves.
  static final RegExp _inert = RegExp(r'(^|/)(docs/|\.github/)|\.md$');

  /// Paths whose reach is the whole application.
  static final RegExp _global = RegExp(
    r'(^|/)(pubspec\.yaml|pubspec\.lock|analysis_options\.yaml)$|'
    r'(^|/)(assets|android|ios|web|macos|linux|windows)/|'
    r'^(packages|integrations|scripts)/',
  );

  ImpactSelection select(List<String> changedFiles) {
    final changes = [
      for (final path in changedFiles)
        path.replaceAll('\\', '/').trim()
      ,
    ]..removeWhere((path) => path.isEmpty);

    if (changes.isEmpty) {
      return ImpactSelection(
        selected: const [],
        skipped: List.of(index.flows),
        isFullSuite: false,
        reason: 'no changes to analyse',
      );
    }

    final relevant = [
      for (final path in changes)
        if (!_inert.hasMatch(path)) path,
    ];

    if (relevant.isEmpty) {
      return ImpactSelection(
        selected: const [],
        skipped: List.of(index.flows),
        isFullSuite: false,
        reason: 'only documentation changed '
            '(${changes.length} file(s)), which cannot alter behaviour',
      );
    }

    // A flow file changing selects that flow, and says nothing about
    // the others.
    final directFlows = <String, String>{};
    final attributed = <IndexedFile>[];
    final unattributed = <String>[];
    final globals = <IndexedFile>[];

    for (final path in relevant) {
      final flow = _flowAt(path);
      if (flow != null) {
        directFlows[flow.name] = 'the flow file $path changed';
        continue;
      }

      // A manifest, a bundled asset, a platform folder, or the test
      // platform's own source. Recognised by path rather than content,
      // and reported with the reason that actually applies instead of
      // the generic "nothing is known about it".
      if (_global.hasMatch(path)) {
        globals.add(IndexedFile(path: path, isGlobal: true));
        continue;
      }

      final known = index.file(path);
      if (known != null && known.isAttributable) {
        if (known.isGlobal) {
          globals.add(known);
        } else {
          attributed.add(known);
        }
        continue;
      }

      unattributed.add(path);
    }

    if (unattributed.isNotEmpty || globals.isNotEmpty) {
      final cause = unattributed.isNotEmpty
          ? 'nothing is known about ${unattributed.first}'
              '${unattributed.length > 1 ? ' and '
                  '${unattributed.length - 1} other file(s)' : ''}'
          : '${globals.first.path} can reach any screen';

      return ImpactSelection(
        selected: List.of(index.flows),
        skipped: const [],
        isFullSuite: true,
        reason: 'running everything: $cause, so no flow can be ruled out',
        reasons: {
          for (final flow in index.flows)
            flow.name: 'selection could not be narrowed',
        },
      );
    }

    // Every change is accounted for. Now a flow may be excluded.
    final selected = <FlowCoverage>[];
    final skipped = <FlowCoverage>[];
    final reasons = Map<String, String>.from(directFlows);

    for (final flow in index.flows) {
      if (reasons.containsKey(flow.name)) {
        selected.add(flow);
        continue;
      }

      final touching = [
        for (final file in attributed)
          if (flow.touchesAnyOf(file)) file,
      ];

      if (touching.isEmpty) {
        skipped.add(flow);
        continue;
      }

      selected.add(flow);
      reasons[flow.name] = _why(flow, touching);
    }

    return ImpactSelection(
      selected: selected,
      skipped: skipped,
      isFullSuite: false,
      reason: '${selected.length} of ${index.flows.length} flow(s) selected '
          'from ${relevant.length} changed file(s)',
      reasons: reasons,
    );
  }

  /// Names the file and the specific overlap, so the choice is
  /// auditable rather than merely asserted.
  String _why(FlowCoverage flow, List<IndexedFile> touching) {
    final parts = <String>[];
    for (final file in touching) {
      final screens = file.screens.where(flow.screens.contains);
      final elements = file.elements.where(flow.elements.contains);
      final overlap = [...screens, ...elements];
      parts.add('${file.path} (${overlap.join(', ')})');
    }
    return 'touches ${parts.join('; ')}';
  }

  FlowCoverage? _flowAt(String path) {
    for (final flow in index.flows) {
      if (flow.path == path) return flow;
    }
    return null;
  }
}
