# UI property resolution

**Status:** implemented.
**Scope:** this issue only. The STOP-1 provenance architecture is
untouched.

---

## The original issue

Surfaced by the STOP-1 milestone, which let a rule run on the external
application that had never been able to run before:

```
✗ rules profile.complete_button: given "data.mobileNumber != null",
  profile.complete_button.text should be Edit/Update Profile but is null
```

The element was **present**, **visible**, and — reading the widget
source — appeared to contain exactly one `Text`. So `.text` should have
resolved. It did not.

The cause was not guessed. The subtree was captured from the device.

## The actual widget tree

`testsmith inspect --tap nav.profile` against ExternalApp on a Samsung
SM-M127G, with the fixture server supplying a loaded profile:

```
TestId #profile.complete_button  text=null  label='Complete Your Profile'
                                 enabled=null  visible=true
                                 bounds=(20,287 344x50)  route=3
  CompleteProfileButton          text=null  label='Complete Your Profile'
                                 enabled=null  visible=true  route=3
    InkWell                      text=null  label='Complete Your Profile'
                                 enabled=true   visible=true  route=3
      GestureDetector            text=null  enabled=null  visible=true
        SvgPicture               text=null  visible=false  bounds=(48,312 0x0)
        Icon                     text=null  visible=true   bounds=(37,301 22x22)
          RichText               text='U+E491'  visible=true
        Text                     text='Complete Your Profile'  visible=true
        SvgPicture               text=null  visible=true
```

There are **two** text-bearing descendants, not one:

| Node | text |
|---|---|
| `Icon` → `RichText` | `'U+E491'` |
| `Text` | `'Complete Your Profile'` |

The ambiguity guard fired exactly as designed, and returned null rather
than guessing. The guard was right; its idea of "text" was wrong.

## Comparison with the working cases

| Target | Shape | Resolved? | Why |
|---|---|---|---|
| `profile.display_name` | `TestKey` **directly on** a `Text` | ✅ | the node carries the text itself |
| `nav.orders` | `TestId` → `InkWell` → `GestureDetector` → [`SvgPicture`, `Text`] | ✅ | its icon is an **`SvgPicture`**, which renders no text — exactly one candidate |
| `profile.complete_button` | `TestId` → … → [`SvgPicture`, **`Icon`**, `Text`, `SvgPicture`] | ❌ | its icon is a Flutter **`Icon`**, which renders through `RichText` |
| a plain `Text` | node carries text | ✅ | — |
| a button/`InkWell` wrapping one `Text` | one candidate | ✅ | — |

The difference between `nav.orders` and `profile.complete_button` is the
kind of icon, and nothing else.

Across the whole captured screen, **4 of the 6 `RichText` nodes are icon
glyphs**: `U+E491`, `U+F193`, `U+F82B`, `U+F37F`.

## Root cause

**A Flutter `Icon` is text, as far as the widget tree is concerned.**

`Icon` builds a `RichText` whose content is a single codepoint in the
Unicode **private-use area** — `U+E491` here — drawn with the
MaterialIcons font. The inspector reads `RichText.text.toPlainText()`
and records it, correctly, as that node's text. Every icon font works
this way: Material, Cupertino, FontAwesome all live in the PUA.

The platform then counted an icon as a piece of user-visible text, which
made any labelled icon button ambiguous between its glyph and its label.

This was invisible until now because the platform's own example app uses
`Image.asset` and bare `Text`, and the external application's navigation
uses `flutter_svg`. The one screen that used a Material `Icon` beside a
label is the one that broke.

## Resolution semantics

`target.text` means **the effective user-visible text of the subtree**,
not the raw field of one node — option **B** of the two the milestone
posed. A semantic id belongs on the thing a person means, which is
frequently a wrapper.

The same fall-through applies to `enabled`, and to nothing else.
`visible`, `label`, `type` and the property bag describe one element;
borrowing them from a child would be a different claim.

A descendant counts as a candidate only when **all** of these hold:

| Rule | Why |
|---|---|
| renders non-empty text | — |
| is **visible**, with non-empty bounds | a zero-area node is not on screen. The `SvgPicture` above is `0x0` |
| is **not an icon glyph** | every rune in a private-use area |
| is **not inside an `Icon`** | belt and braces: catches an icon whose glyph is outside the PUA |
| belongs to the **same route** | a screen underneath must not answer for the one in front (D-12) |

Then:

```
exactly one distinct candidate   → resolve it
zero candidates                  → null, as before
two or more that disagree        → ERROR, naming every candidate
```

**Candidates that all say the same thing are one answer, not several.** A
`TextField` and the `EditableText` inside it both report the value; that
is one string stated twice.

Icons are detected by **codepoint**, not by widget type alone, because an
icon is also legitimately drawn with `Text(String.fromCharCode(...))` and
a font family. Nothing outside the private-use area is affected — no
real copy lives there, by definition of the range.

## Ambiguity handling

Ambiguity is now an **ERROR**, where it previously produced a null that
read as a wrong value:

```
ERROR api-to-ui profile.card: reading "text" is ambiguous: 2 descendants
answer, and they disagree - "Title", "Subtitle". Put the id on the
element that carries the value, or assert on a descendant directly.
```

That is a tool-level statement, not a claim about the application, so it
is an error rather than a failure — and it still blocks a pass. The
message names every candidate and the two ways to resolve it.

`readProperty` is kept for callers that cannot express an error (a flow
step's message, a diagnostic) and returns null on ambiguity. Validators
use `readPropertyOf`, which returns a sealed `PropertyRead`.

## Security behaviour

Descendant traversal does **not** reach around the masking that capture
applied. The SDK masks an obscured field at capture time — it never
enters the tree in the clear — so traversal has nothing to find.

Tested on both sides of the seam:

- **In the SDK, on real widget trees**, for five secret kinds — password,
  OTP, card number, CVV, authorization token. A `TestId` wrapping an
  `obscureText: true` field is captured, and the **entire serialised
  subtree** is then searched for the literal secret. It is not there: the
  field reads `[REDACTED]:24` — the marker plus a length, never the
  characters.
- **In the engine, on a masked subtree**, traversal resolves to that
  marker and to nothing else. Descendant traversal cannot reach around
  masking, because there is nothing behind it to reach.

Two further properties, each its own test:

- a label beside a masked field is an ambiguity, and every candidate
  named in the error message is already masked;
- a field the application did **not** obscure is still readable —
  redaction must not become a blanket refusal to read text.

## Tests

**25** in `packages/flutter_testsmith_engine/test/ui_property_resolution_test.dart`,
written before the fix and failing against it (`readPropertyOf`,
`PropertyValue` and `PropertyAmbiguous` did not exist), covering every
case the milestone required:

| # | Case | Result |
|---|---|---|
| 1 | TestId directly on `Text` | reads its own text |
| 2 | TestId on `InkWell` with one `Text` | resolves |
| 3 | TestId on `GestureDetector` with one `Text` | resolves |
| 4 | TestId on a button wrapper with one `Text` | resolves |
| 5 | Multiple text descendants | **ERROR**, candidates named |
| 6 | No text descendants | null |
| 7 | Text on a hidden descendant | ignored |
| 8 | Text on a descendant from a route underneath | ignored |
| 9 | `profile.display_name` behaviour | unchanged |
| 10 | `enabled` behaviour | unchanged |

Plus: the icon glyph isolated on its own; identical texts not ambiguous;
`visible` / `label` / `type` untouched; `readProperty` still returning a
plain value; and four tests over the **tree captured from the device**,
including one asserting the tree really does contain ≥4 icon glyphs — so
that the fixture cannot silently stop proving anything.

**7** more in `packages/flutter_testsmith/test/secret_leakage_test.dart` for the
security behaviour above.

## Device evidence

Samsung SM-M127G, ExternalApp, fixture server:

```
✓ ui-presence profile.display_name: "profile.display_name" is present
✓ api-to-ui   profile.display_name: response.data.firstName matches
              profile.display_name.text (from GET /api/profile/me
              captured on "/", 2s earlier)
✓ rules       profile.complete_button: given "data.lastName == """,
              profile.complete_button.text is Complete Your Profile
✓ rules       profile.complete_button: given "data.mobileNumber != null",
              profile.complete_button.enabled is true
✓ visual      "/profile" matches the baseline: 0.000% of 1076400 pixels
              differ, ssim 1.0000

/profile  PASS  5 ok, 0 failed, 1 skipped, 0 errored
```

The assertion that read `null` now reads `Complete Your Profile`.

The complete external-app flow suite, on the same device:

| Flow | Result |
|---|---|
| `home` | PASS (`/` and `/home`) |
| `orders` | PASS |
| `profile` | PASS — 5 ok, 0 failed |

## Newly discovered limitations

- **An icon-only button has no text, by design.** `.text` on a target
  whose only child is an `Icon` resolves to null rather than to the
  glyph. Assert on `label` — the semantics label — instead. The captured
  tree shows `label='Complete Your Profile'` on the wrapper, which is
  often the better assertion anyway.
- **`label` does not fall through.** It reads the node only. On the
  external application the `InkWell` two levels down carried a useful
  semantics label that a wrapper id cannot reach. Deliberate for now,
  because a semantics label aggregates children and borrowing one would
  frequently be wrong — but it means two properties on the same node
  follow different rules, which is a wart.
- **Ambiguity cannot be resolved from the mappings file.** There is no
  `textFrom:` to name which descendant is meant; the only fix is to move
  the id. Not yet needed by any measured case.
- **A private-use codepoint that is genuinely content would be
  ignored.** No real copy uses that range, but the rule is a heuristic
  about Unicode rather than a fact about the widget.
