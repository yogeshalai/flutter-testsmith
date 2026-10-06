import 'package:meta/meta.dart';

import '../secrets/secret_ref.dart';
import '../validation/api_expectation.dart';
import '../validation/response_source.dart';

/// One action or assertion in a flow.
///
/// Sealed, so the executor's switch is checked for exhaustiveness:
/// adding a step forces every place that runs one to handle it, rather
/// than silently doing nothing.
@immutable
sealed class Step {
  const Step();

  /// One line for the report.
  String describe();
}

final class LaunchAppStep extends Step {
  const LaunchAppStep();

  @override
  String describe() => 'launch the app';
}

final class WaitForSettleStep extends Step {
  const WaitForSettleStep({this.timeout = const Duration(seconds: 10)});

  final Duration timeout;

  @override
  String describe() => 'wait for the screen to settle';
}

final class TapStep extends Step {
  const TapStep(this.elementId);

  final String elementId;

  @override
  String describe() => 'tap "$elementId"';
}

final class InputStep extends Step {
  const InputStep({required this.elementId, required this.value});

  final String elementId;
  final String value;

  @override
  String describe() => 'type "$value" into "$elementId"';
}

/// Types a credential into a field, naming only where it came from.
///
/// Not a flag on [InputStep]: that step's `describe()` renders the
/// value, which is exactly right for a test step and exactly wrong for a
/// credential. A separate type makes the safe rendering the only
/// rendering.
///
/// Declared here because [Step] is `sealed` and Dart permits subclasses
/// only in the declaring library - which is a benefit rather than a
/// nuisance: the executor's switch is checked for exhaustiveness, so
/// this forces an explicit decision at the one place that runs product
/// flows.
///
/// Only an auth flow may contain one. `TestFlow.parse` cannot produce
/// one, and `FlowExecutor` refuses one.
final class SecretInputStep extends Step {
  const SecretInputStep({required this.elementId, required this.ref});

  final String elementId;

  /// The reference, never the value. This is what reaches the report.
  final SecretRef ref;

  @override
  String describe() => 'type <$ref> into "$elementId"';
}

final class BackStep extends Step {
  const BackStep();

  @override
  String describe() => 'press back';
}

final class ExpectScreenStep extends Step {
  const ExpectScreenStep(
    this.screenId, {
    this.timeout = const Duration(seconds: 5),
  });

  final String screenId;

  /// How long to wait for the screen to appear.
  ///
  /// Not instantaneous: navigation events travel from the app over the
  /// VM Service, so checking the moment a tap returns races the event
  /// it is asserting about. Measured on a device, that race failed
  /// reporting the app was still on the previous screen.
  final Duration timeout;

  @override
  String describe() => 'expect to be on "$screenId"';
}

/// Asserts one fact about one element of the current screen.
///
/// Added in Phase 12, because until then a flow could navigate and
/// validate and nothing else - which is enough for a happy path and
/// useless for an error one. With an `api_500` fixture in play, every
/// mapped element is legitimately absent and `validateScreen` reports
/// error; there was no way to say "and that is what should happen".
///
/// Deliberately narrow. This asserts presence, visibility, enabled state
/// or text on an element that is named - not an expression language.
/// Anything more belongs in a mapping or a rule, where it is declared
/// once for the screen rather than restated in every flow that visits it.
final class ExpectElementStep extends Step {
  const ExpectElementStep({
    required this.elementId,
    this.present,
    this.enabled,
    this.visible,
    this.text,
    this.textContains,
    this.timeout = const Duration(seconds: 5),
  });

  final String elementId;

  /// Whether the element must be on the screen at all.
  final bool? present;

  final bool? enabled;
  final bool? visible;

  /// Exact text.
  final String? text;

  /// A substring, for a message whose wording is not the point.
  final String? textContains;

  final Duration timeout;

  /// Every assertion this step makes, as `property: expected`.
  Map<String, Object?> get expectations => {
        if (present != null) 'present': present,
        if (enabled != null) 'enabled': enabled,
        if (visible != null) 'visible': visible,
        if (text != null) 'text': text,
        if (textContains != null) 'textContains': textContains,
      };

  @override
  String describe() {
    final parts = [
      for (final entry in expectations.entries)
        '${entry.key} = ${entry.value}',
    ];
    return parts.isEmpty
        ? 'expect "$elementId" to exist'
        : 'expect "$elementId" ${parts.join(', ')}';
  }
}

final class ScreenshotStep extends Step {
  const ScreenshotStep(this.name);

  final String name;

  @override
  String describe() => 'take a screenshot named "$name"';
}

/// Runs the deterministic validators over the current screen.
///
/// Each dimension is opt-in, and one not asked for is *skipped* rather
/// than passed - a dimension that was never checked must not read as
/// evidence the screen is correct.
/// Asserts that the application called an endpoint and what came back.
///
/// The bridge between UI testing and API testing, and the reason it is a
/// **step** rather than another flag on `validateScreen`: an assertion
/// about the API is only meaningful at a point in time. "The dashboard
/// answered 200" says something after the tab was tapped and nothing
/// before it, and a flow that can interleave the two is a flow that can
/// describe a login: tap, assert the token came back, arrive, assert the
/// dashboard came back, then photograph.
///
/// It reads what the **application** received, through the SDK's
/// capture. Asserting against the fixture server's own log would prove
/// only that the fixture server works.
final class ExpectApiStep extends Step {
  const ExpectApiStep({
    required this.endpoint,
    required this.status,
    this.occurrence = ResponseOccurrence.only,
    this.expectations = const [],
    this.timeout = const Duration(seconds: 10),
  });

  final ApiEndpoint endpoint;

  /// The status the application must have received.
  ///
  /// Required, with no default. A step that asserts an endpoint was
  /// called and says nothing about the answer would pass against a 500,
  /// and this exists because a screen rendered from a failed request
  /// looks fine in a photograph.
  final int status;

  /// Which exchange is meant when the endpoint was called more than
  /// once. [ResponseOccurrence.only] refuses rather than guessing.
  final ResponseOccurrence occurrence;

  /// Assertions about fields of the response body.
  final List<ApiExpectation> expectations;

  /// How long to wait for the exchange to appear.
  ///
  /// Waited for rather than read once: the assertion follows a tap, and
  /// the request travels to the host and the event back over the VM
  /// Service. A single read turns a slow machine into a failure.
  final Duration timeout;

  @override
  String describe() {
    final fields = expectations.isEmpty
        ? ''
        : ', ${expectations.length} '
            '${expectations.length == 1 ? 'field' : 'fields'}';
    return 'expect $endpoint to have answered $status$fields';
  }
}

/// Validates the current screen with every check that applies.
///
/// Each flag is **tri-state**: `true` and `false` mean what they say,
/// and absent means "decide automatically". A bare `validateScreen`
/// therefore runs the lot, which is what the specification asks for -
/// one step, not a list of flags to keep in sync with the phases that
/// have shipped.
///
/// Enabling everything is safe because a validator with nothing to work
/// from skips with a reason rather than failing. A screen with no Figma
/// design still shows a `figma` row in the report, saying why it could
/// not be checked - which is more useful than the row being absent.
final class ValidateScreenStep extends Step {
  const ValidateScreenStep({
    this.api,
    this.ui,
    this.rules,
    this.figma,
    this.visual,
  });

  /// Null means automatic. See [runsApi] and friends for what that
  /// resolves to.
  final bool? api;
  final bool? ui;
  final bool? rules;
  final bool? figma;
  final bool? visual;

  bool get runsApi => api ?? true;
  bool get runsUi => ui ?? true;
  bool get runsRules => rules ?? true;
  bool get runsFigma => figma ?? true;

  /// Whether to compare the screenshot.
  ///
  /// The only check that *writes*: with no baseline it records one.
  /// Automatic mode therefore requires a baseline to already exist -
  /// putting a screenshot into the repository should be a decision
  /// someone made, not a side effect of running the suite. Asking for
  /// it explicitly records one on a first run.
  bool runsVisual({required bool hasBaseline}) => visual ?? hasBaseline;

  /// True when nothing was named, so every choice is ours.
  bool get isAutomatic =>
      api == null &&
      ui == null &&
      rules == null &&
      figma == null &&
      visual == null;

  @override
  String describe() {
    if (isAutomatic) return 'validate the screen (automatic)';

    final named = [
      if (api != null) 'api${api! ? '' : ':off'}',
      if (ui != null) 'ui${ui! ? '' : ':off'}',
      if (rules != null) 'rules${rules! ? '' : ':off'}',
      if (figma != null) 'figma${figma! ? '' : ':off'}',
      if (visual != null) 'visual${visual! ? '' : ':off'}',
    ];
    return 'validate the screen (${named.join(', ')}, rest automatic)';
  }
}

/// What a step *was*, as it appears on the run wire.
///
/// A vocabulary of its own rather than a class name. `runtimeType` is
/// not a contract: renaming a Dart class would silently change every
/// artefact written afterwards, and a reader of an old report would have
/// no way to tell. These strings are the contract, and they change only
/// with a schema version.
///
/// Introduced at run schema 1.3. Before it, a report had to work out
/// what a step was from [Step.describe] - presentation text carrying
/// user-supplied values - which misread an `expectElement` whose
/// expected text happened to contain the phrase an `expectApi`
/// description uses.
enum StepKind {
  launchApp('launchApp'),
  waitForSettle('waitForSettle'),
  tap('tap'),
  input('input'),
  secretInput('secretInput'),
  back('back'),
  expectScreen('expectScreen'),
  expectElement('expectElement'),
  screenshot('screenshot'),
  expectApi('expectApi'),
  validateScreen('validateScreen');

  const StepKind(this.wire);

  /// The string written to `steps[].kind`.
  final String wire;
}

/// The kind of [step], decided by its concrete type and nothing else.
///
/// Exhaustive over the sealed hierarchy on purpose: adding a [Step] stops
/// this compiling until someone says what kind it is. That is the whole
/// guarantee - a new step cannot reach a report as an unknown.
///
/// Reads no text. Not `describe()`, not `runtimeType`, not the endpoint,
/// not the status: a report must not be able to change its mind about
/// what a step was because someone reworded a sentence.
StepKind stepKindOf(Step step) => switch (step) {
      LaunchAppStep() => StepKind.launchApp,
      WaitForSettleStep() => StepKind.waitForSettle,
      TapStep() => StepKind.tap,
      InputStep() => StepKind.input,
      SecretInputStep() => StepKind.secretInput,
      BackStep() => StepKind.back,
      ExpectScreenStep() => StepKind.expectScreen,
      ExpectElementStep() => StepKind.expectElement,
      ScreenshotStep() => StepKind.screenshot,
      ExpectApiStep() => StepKind.expectApi,
      ValidateScreenStep() => StepKind.validateScreen,
    };
