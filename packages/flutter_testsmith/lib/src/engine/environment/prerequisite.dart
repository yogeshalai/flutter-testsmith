/// Who or what is responsible for something a suite needs before it can
/// test anything.
///
/// This classification is the point of E-04. "The run failed" is not
/// actionable and, worse, is usually not even true: a device missing a
/// permission has told you nothing about the application. Naming the
/// owner is what lets a report say *which* of those two happened, and
/// therefore which person to send it to.
enum PrerequisiteClass {
  /// The runner establishes it, every run, out of something in the
  /// repository. If it is wrong, the fix is a file somebody can review.
  runnerControlled('runnerControlled'),

  /// The application decides it and the runner only observes. Whether
  /// the SDK arms, and which route a cold start lands on, are both this:
  /// the runner can read them and must not manufacture them.
  applicationControlled('applicationControlled'),

  /// A property of the handset the runner can read but must not silently
  /// change. A missing one is a configuration result, never a product
  /// failure.
  devicePrerequisite('devicePrerequisite'),

  /// Something off this machine. A deterministic test must never need
  /// one; the class exists so a report can say plainly when something
  /// did.
  externalService('externalService'),

  /// A person has to do it. Recorded rather than automated - usually
  /// because automating it would mean bypassing the very thing it
  /// establishes.
  humanAction('humanAction');

  const PrerequisiteClass(this.wire);

  /// The name this class is written under in a report.
  final String wire;
}
