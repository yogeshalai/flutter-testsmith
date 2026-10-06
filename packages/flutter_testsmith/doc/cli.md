# The `testsmith` CLI

`testsmith`, the command-line runner for Flutter Testsmith.

Until ADR-0011 it was its own package, `flutter_testsmith_cli`. It now lives
in `lib/src/cli/` of `flutter_testsmith`, with its entry point at
`bin/testsmith.dart`, and this page was that package's README.

It launches a Flutter application on an Android device, drives it through
a YAML flow by semantic test id, and validates each screen against the
API response behind it, a normalised Figma frame and an accepted
screenshot baseline. It then writes `result.json` and `report.html`, and
on request asks a language model to explain whatever failed.

The CLI does argument parsing and output formatting only. The work is
done by the engine (`package:flutter_testsmith/engine.dart`); the
application under test carries the in-app SDK
(`package:flutter_testsmith/flutter_testsmith.dart`). All three come in the
one package.

## Installation

From the application that depends on `flutter_testsmith`:

```bash
dart run flutter_testsmith:testsmith doctor
```

`dart pub global activate flutter_testsmith` also installs a `testsmith`
launcher. pub runs global executables of packages that need the Flutter
SDK only from the snapshot it builds at activation, so activate again
after upgrading the Dart SDK (ADR-0011).

### Requirements

- `flutter` on `PATH`. It is found there and nowhere else.
- `adb`, found from `MYTEST_ADB`, then `ANDROID_HOME`, then
  `ANDROID_SDK_ROOT`, then `PATH`. `testsmith doctor` reports which one
  was used.
- An attached Android device or emulator for anything that runs the
  application.

## Commands

| Command | Does |
|---|---|
| `doctor` | Check that this machine has everything needed to run tests |
| `devices` | List attached Android devices and emulators |
| `preflight` | Check that this environment can run a suite, before it runs one |
| `smoke` | Launch the app, attach over the VM Service, and verify the channel |
| `inspect` | Capture and print the semantic UI tree of the current screen |
| `run` | Run a test flow and write a report |
| `suite run` | Run every flow a suite declares, in order |
| `auth setup` | Sign in on the device through the real login UI, and verify it |
| `figma pull` | Fetch a frame and normalise it into a design specification |
| `impact` | Show which test flows a set of changes makes worth running |
| `generate` | Propose edge-case test scenarios, which never run until a person accepts them |

`testsmith help <command>` lists every option.

## Example

From the application's directory:

```bash
testsmith run tests/product.yaml -d <serial> --mock-api 8080
```

```yaml
# tests/product.yaml
appId: com.example.shop
flow: product_details

steps:
  - launchApp
  - waitForSettle
  - tap:
      id: home.open_product
  - expectScreen:
      id: /product/details
  - waitForSettle
  - validateScreen
```

`validateScreen` runs every check that has configuration and reports why
any other could not run, rather than going quiet. Project assets live
beside the application: `mappings/`, `tests/`, `figma/`, `auth/`,
`device_profiles/`, `visual_baselines/` and `mock_api/`.

### Where things resolve

- The application is `--app` if given, otherwise the nearest directory at
  or above the current one holding a `pubspec.yaml`.
- A relative `--out` is relative to the application, not to the shell.
- Credentials come from the process environment first, then a `.env`
  beside the application. Secrets are referenced by variable name; a
  literal key in `ai.yaml` is a parse error.

## Exit codes

| Code | Means |
|---|---|
| 0 | Passed. Checks reported as `skip` say why they could not be made. |
| 1 | A check failed: the application did something wrong. |
| 2 | Nothing could be evaluated: environment, configuration, device or connection. Not a test failure. |

## Limitations

- Android only.
- One device per invocation.
- Visual baselines are per device resolution, and are never re-recorded
  unless you pass `--update-visual-baselines`.

## Status

Pre-release (0.x). Flags and output formats may still change between
minor versions.
