/// Provider-agnostic access to a chat completion model.
///
/// This component knows nothing about testing, Flutter, or validation. It
/// sends a prompt and returns text. That narrowness is the point: the
/// provider and model are configuration values, so moving from Groq to
/// a local Ollama or to OpenAI changes a YAML file and nothing else.
library;

export 'src/ai/llm_client.dart';
export 'src/ai/llm_config.dart';
export 'src/ai/openai_compatible_client.dart';
