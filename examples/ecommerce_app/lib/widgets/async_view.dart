import 'package:flutter/material.dart';
import 'package:flutter_testsmith/flutter_testsmith.dart';

import '../api/api_client.dart';

/// The four states every screen that loads something can be in.
///
/// One implementation, shared, because the alternative is each screen
/// inventing its own and "empty" quietly rendering as "loading" on one
/// of them. A test platform that has to learn a different shape per
/// screen cannot say anything general about the application.
enum LoadState { loading, error, empty, data }

/// Holds whatever one screen loaded, plus how it went.
class Loaded<T> {
  const Loaded.loading()
      : state = LoadState.loading,
        value = null,
        error = null;

  const Loaded.error(ApiException this.error)
      : state = LoadState.error,
        value = null;

  const Loaded.empty()
      : state = LoadState.empty,
        value = null,
        error = null;

  const Loaded.data(T this.value)
      : state = LoadState.data,
        error = null;

  final LoadState state;
  final T? value;
  final ApiException? error;
}

/// Renders one of the four states, with a semantic id on each.
///
/// The ids are the contract: a flow asserts `<prefix>.loading` is gone
/// and `<prefix>.empty` is present, and that assertion means the same
/// thing on every screen.
class AsyncView<T> extends StatelessWidget {
  const AsyncView({
    super.key,
    required this.idPrefix,
    required this.loaded,
    required this.builder,
    required this.onRetry,
    this.emptyMessage = 'Nothing here yet',
  });

  final String idPrefix;
  final Loaded<T> loaded;
  final Widget Function(BuildContext, T) builder;
  final VoidCallback onRetry;
  final String emptyMessage;

  @override
  Widget build(BuildContext context) {
    switch (loaded.state) {
      case LoadState.loading:
        return Center(
          child: CircularProgressIndicator(key: TestKey('$idPrefix.loading')),
        );

      case LoadState.error:
        final error = loaded.error!;
        return Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  error.userMessage,
                  key: TestKey('$idPrefix.error'),
                  textAlign: TextAlign.center,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
                const SizedBox(height: 8),
                // The status, on screen, because diagnosing a device run
                // from a screenshot is otherwise guesswork.
                Text(
                  error.isTimeout
                      ? 'timeout'
                      : 'status ${error.statusCode ?? 'none'}',
                  key: TestKey('$idPrefix.error_code'),
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                const SizedBox(height: 16),
                FilledButton(
                  key: TestKey('$idPrefix.retry'),
                  onPressed: onRetry,
                  child: const Text('Try again'),
                ),
              ],
            ),
          ),
        );

      case LoadState.empty:
        return Center(
          child: Text(emptyMessage, key: TestKey('$idPrefix.empty')),
        );

      case LoadState.data:
        return builder(context, loaded.value as T);
    }
  }
}
