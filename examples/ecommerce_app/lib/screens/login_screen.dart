import 'package:flutter/material.dart';
import 'package:flutter_testsmith/flutter_testsmith.dart';

import '../api/api_client.dart';
import '../app.dart';
import 'home_screen.dart';

/// The way in. Exists mainly so there is a screen that sends a password
/// and receives a token - the two credentials most worth proving never
/// reach a report.
class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  static const String route = '/login';

  /// The seeded password. Constant so the security matrix can grep for
  /// it in every artefact a run produces.
  static const String seededPassword = 'SEEDED_PASSWORD_c41e77b0';

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final TextEditingController _email =
      TextEditingController(text: 'test.user@example.com');
  final TextEditingController _password =
      TextEditingController(text: LoginScreen.seededPassword);

  bool _busy = false;
  ApiException? _error;

  @override
  void dispose() {
    _email.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    setState(() {
      _busy = true;
      _error = null;
    });

    try {
      await AppScope.of(context).login(
        email: _email.text,
        password: _password.text,
      );
      if (!mounted) return;
      Navigator.of(context).pushReplacementNamed(HomeScreen.route);
    } on ApiException catch (error) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = error;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final error = _error;

    return Scaffold(
      appBar: AppBar(title: const Text('Sign in')),
      body: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextField(
              key: const TestKey('login.email'),
              controller: _email,
              decoration: const InputDecoration(labelText: 'Email'),
            ),
            const SizedBox(height: 12),
            TextField(
              key: const TestKey('login.password'),
              controller: _password,
              obscureText: true,
              decoration: const InputDecoration(labelText: 'Password'),
            ),
            const SizedBox(height: 24),
            FilledButton(
              key: const TestKey('login.submit'),
              // Disabled while in flight, so a double tap cannot open two
              // sessions - and so there is a genuine `enabled: false`
              // state on a real screen for a rule to assert on.
              onPressed: _busy ? null : _submit,
              child: Text(_busy ? 'Signing in…' : 'Sign in'),
            ),
            if (_busy) ...[
              const SizedBox(height: 24),
              const Center(
                child: CircularProgressIndicator(
                  key: TestKey('login.loading'),
                ),
              ),
            ],
            if (error != null) ...[
              const SizedBox(height: 24),
              Text(
                error.userMessage,
                key: const TestKey('login.error'),
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
              Text(
                error.isTimeout
                    ? 'timeout'
                    : 'status ${error.statusCode ?? 'none'}',
                key: const TestKey('login.error_code'),
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
            const Spacer(),
            Text(
              TestSdk.isArmed
                  ? 'test instrumentation: ARMED'
                  : 'test instrumentation: off',
              key: const TestKey('login.sdk_status'),
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ),
      ),
    );
  }
}
