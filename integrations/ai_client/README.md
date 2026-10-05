# ai_client

Provider-agnostic access to a chat completion model. A prompt goes in,
text comes out.

This package knows nothing about testing, Flutter or validation, and that
narrowness is the point: the provider and model are configuration
values, so moving from Groq to a local Ollama or to OpenAI changes a YAML
file and nothing else.

In Flutter Testsmith it sits under `flutter_testsmith_engine`, which uses
it to explain failures after a verdict is computed and to propose test
scenarios for a person to review. It never sees a verdict it could
change.

## Installation

```yaml
dependencies:
  ai_client: ^0.1.0
```

Pure Dart; no Flutter dependency.

## Usage

```dart
import 'dart:io';

import 'package:ai_client/ai_client.dart';

Future<void> main() async {
  final config = LlmConfig.forProvider('groq');
  final LlmClient client = OpenAiCompatibleClient(
    config: config,
    apiKey: Platform.environment[config.apiKeyEnv],
  );

  final completion = await client.complete(
    const LlmPrompt(
      system: 'Answer in one sentence.',
      user: 'Why is a passing test without assertions worthless?',
    ),
  );
  print('${client.describe}: ${completion.content}');
}
```

`LlmCompletion.model` is the model the provider says answered, which may
differ from the one requested.

## Configuration

`LlmConfig.parse` reads an `ai.yaml`:

```yaml
provider: groq                 # or openai, openrouter, together, ollama, custom
model: openai/gpt-oss-120b
apiKeyEnv: GROQ_API_KEY        # the NAME of the variable, never the key
temperature: 0
```

Writing the key itself into the file (`apiKey:`, `api_key:`, `key:` or
`token:`) is a parse error: a configuration file that can carry a secret
eventually carries one into version control. Known providers supply
their endpoint and key variable; `custom` takes a `baseUrl`.

## Supported providers

Anything that speaks the OpenAI chat-completions shape
(`POST {baseUrl}/chat/completions`): Groq, OpenAI, OpenRouter, Together,
Ollama and other compatible endpoints. Anthropic's Messages API has a
different wire format; selecting it raises an `LlmException` explaining
that no client exists for it yet, rather than sending a request it
cannot parse.

## Errors

Every failure is an `LlmException`, with the HTTP status when there was
one and a `retryable` flag. A missing key fails at construction, naming
the environment variable to set, and is deliberately not accepted as a
command-line flag where it would end up in shell history.

## Status

Pre-release (0.x). The API may still change between minor versions.
