# The Figma component (`package:flutter_testsmith/figma.dart`)

Fetches Figma frames and normalises them into a `FigmaScreenSpec`: a
design specification Flutter Testsmith can compare a running Flutter
screen against for structure, element kind, geometry, order, typography
and colour.

Until ADR-0011 it was its own package, `flutter_testsmith_figma`. It now
lives in `lib/src/figma/` of `flutter_testsmith`, and this page was that
package's README.

It is the design side of that comparison and nothing else. It knows the
Figma REST API and the shape of a design. The comparison itself, scaling
a design to a device and deciding pass or fail, belongs to the engine
(`package:flutter_testsmith/engine.dart`). Most people use it through
`testsmith figma pull` rather than directly.

> Developed as `figma_client`, a name owned on pub.dev by an unrelated
> package, then as `flutter_testsmith_figma`. The Dart API
> (`FigmaClient`, `FigmaNormaliser`, `FigmaScreenSpec`,
> `FigmaNodeMapping`) is unchanged by either rename.

## Installation

It comes with `flutter_testsmith`; there is nothing extra to add:

```dart
import 'package:flutter_testsmith/figma.dart';
```

Pure Dart: its code never imports Flutter (rule B in
`scripts/check_dependencies.dart`).

## Usage

```dart
import 'dart:io';

import 'package:flutter_testsmith/figma.dart';

Future<void> main() async {
  final target = FigmaTarget.parseUrl(
    'https://www.figma.com/design/<fileKey>/Shop?node-id=12-34',
  );

  final client = FigmaClient(
    token: Platform.environment['FIGMA_TOKEN']!,
    cacheDirectory: Directory('figma/.cache'),
  );
  final response = await client.fetchNode(
    fileKey: target.fileKey,
    nodeId: target.nodeId,
  );

  final mapping = FigmaNodeMapping.parse(
    File('figma/product_details.mapping.yaml').readAsStringSync(),
    source: 'figma/product_details.mapping.yaml',
  );

  final spec = const FigmaNormaliser().normalise(
    response,
    nodeId: target.nodeId,
    screen: '/product/details',
    mapping: mapping,
  );
  print('${spec.elements.length} elements');
}
```

`FigmaTarget.parseUrl` accepts the URL's `node-id=12-34` form and
converts it to the API's `12:34`.

## Mapping design nodes to test ids

Real design layers are called `Frame 42980` and `Rectangle 91`, so a
layer name is never treated as a semantic id. A mapping file binds Figma
**node ids**, which survive a rename, to the application's test ids:

```yaml
screen: /product/details
nodes:
  "12:40": product.image
  "12:41": product.name
  "12:42": product.price
```

Each semantic id may come from one node only; a second claim is a
`FormatException`, not a silent overwrite.

## Behaviour worth knowing

- **Responses are cached on disk** when a `cacheDirectory` is given.
  Figma rate-limits, and a design does not change between two steps of a
  run. Pass `refresh: true` to `fetchNode` to bypass the cache. A
  response that is not a design, such as a gateway error page, is never
  cached.
- **Every failure is a `FigmaException`**: a rejected token, a missing
  node, an unreachable host, a TLS failure or a malformed body. The token
  never appears in an exception message.
- **Figma is optional** to the platform. With no design available,
  validation reports a skip, not a failure.

## Status

Pre-release (0.x). The API may still change between minor versions.
