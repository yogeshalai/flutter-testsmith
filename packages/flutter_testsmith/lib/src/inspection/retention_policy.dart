/// Which elements are worth putting on the wire.
///
/// A raw Flutter element tree for a typical screen runs to thousands of
/// nodes, almost all of them layout scaffolding. Shipping that on every
/// screen transition is slow to send and unreadable in a report. Filtering
/// too hard, though, and the tree stops being a faithful functional record
/// - so the rules are explicit, and configurable per project. See ADR-0005
/// and risk R4.
class UiRetentionPolicy {
  const UiRetentionPolicy({
    required this.interestingTypes,
    required this.interestingTypeSuffixes,
    this.retainAll = false,
  });

  /// The default: anything with a test id, anything semantically
  /// meaningful, and nothing else.
  const UiRetentionPolicy.defaults()
      : interestingTypes = const {
          'Text',
          'RichText',
          'EditableText',
          'TextField',
          'TextFormField',
          'Image',
          'Icon',
          'Checkbox',
          'Radio',
          'Switch',
          'Slider',
          'Chip',
          'Card',
          'ListTile',
          'ListView',
          'GridView',
          'PageView',
          'SingleChildScrollView',
          'Scrollable',
          'AppBar',
          'TabBar',
          'Tab',
          'Dialog',
          'AlertDialog',
          'SnackBar',
          'BottomNavigationBar',
          'NavigationBar',
          'ProgressIndicator',
          'CircularProgressIndicator',
          'LinearProgressIndicator',
        },
        // Catches ElevatedButton, FilledButton, TextButton, IconButton,
        // OutlinedButton and anyone's custom *Button without naming them
        // all.
        interestingTypeSuffixes = const {'Button'},
        retainAll = false;

  /// Retains every element. Diagnostic only - the payload is large.
  const UiRetentionPolicy.everything()
      : interestingTypes = const {},
        interestingTypeSuffixes = const {},
        retainAll = true;

  final Set<String> interestingTypes;
  final Set<String> interestingTypeSuffixes;
  final bool retainAll;

  /// Whether an element is worth keeping on its own merits.
  ///
  /// Having a test id or carrying semantics is decided by the caller;
  /// this answers only the "is this type interesting" half.
  bool isInterestingType(String type) {
    if (retainAll) return true;
    if (interestingTypes.contains(type)) return true;
    for (final suffix in interestingTypeSuffixes) {
      if (type.endsWith(suffix)) return true;
    }
    return false;
  }
}
