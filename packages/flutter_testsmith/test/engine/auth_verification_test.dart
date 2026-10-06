// The whole state matrix, decided without a handset.
//
// Every case in the design's section 11 is here, plus the precedence in
// section 9.0 - because more than one rule can be true at once, and the
// most specific answer is the most useful one.

import 'package:test/test.dart';
import 'package:flutter_testsmith/engine.dart';

const String _yaml = '''
auth: t
app: {path: ., target: lib/main_uat.dart, flavor: f}
appId: com.example.package
sdkAppId: com.example.sdkidentity
device: {profile: p}
secrets: {pin: env:MYTEST_AUTH_PIN}
signedOutOn: [/onboarding, /login]
login:
  - inputSecret: {id: pin_field, secret: pin}
  - tap: {id: continue_button}
verify:
  route: /home
  element: home.body
  request: {endpoint: POST /login/consumer, status: 200}
  notOn: [/set-location, /otp-verification, /registration-otp]
  invalidCredentialOn: {route: /secure-login, element: login.pin_error}
''';

final AuthFile file = AuthFile.parse(_yaml, source: 'test');

ApiExpectationOutcome _request({required bool satisfied}) =>
    ApiExpectationOutcome(
      endpoint: 'POST /login/consumer',
      status: satisfied ? 200 : 401,
      failures: satisfied ? const [] : const ['expected 200, received 401'],
    );

AuthObservations _seen({
  String? route = '/home',
  List<String> routeHistory = const ['/', '/login', '/home'],
  bool loginPerformed = true,
  bool elementPresent = true,
  ApiExpectationOutcome? request,
  // Distinct from `request: null`, which cannot be told apart from "not
  // specified" and would silently fall through to the satisfied default.
  bool noRequest = false,
  bool invalidCredentialVisible = false,
  bool loginUiMissing = false,
  bool environmentBlocked = false,
  bool secretMissing = false,
  String? flowFailure,
  String? reportedAppId = 'com.example.sdkidentity',
}) =>
    AuthObservations(
      route: route,
      routeHistory: routeHistory,
      loginPerformed: loginPerformed,
      elementPresent: elementPresent,
      request: noRequest ? null : (request ?? _request(satisfied: true)),
      invalidCredentialVisible: invalidCredentialVisible,
      loginUiMissing: loginUiMissing,
      environmentBlocked: environmentBlocked,
      secretMissing: secretMissing,
      flowFailure: flowFailure,
      reportedAppId: reportedAppId,
    );

void main() {
  group('case A - a real login succeeded', () {
    test('every term held, so there is no failure', () {
      expect(classifyAuthSetup(file: file, seen: _seen()), isNull);
    });
  });

  group('case B - already authenticated', () {
    test(
        'a cold start that reached /home without passing a signed-out '
        'route needs no login request', () {
      final verdict = classifyAuthSetup(
        file: file,
        seen: _seen(
          loginPerformed: false,
          routeHistory: const ['/', '/home'],
          noRequest: true,
        ),
      );
      expect(verdict, isNull);
    });

    test('a guest who navigated to /home is not accepted as a session', () {
      // /home is guest-browsable. What a guest cannot do is *start*
      // there, so the route history is what carries the proof.
      final verdict = classifyAuthSetup(
        file: file,
        seen: _seen(
          loginPerformed: false,
          routeHistory: const ['/', '/login', '/home'],
          noRequest: true,
        ),
      );
      expect(verdict, AuthSetupFailure.authenticatedStateNotReached);
    });
  });

  group('case C - invalid credentials', () {
    test('the application saying so is what decides it', () {
      final verdict = classifyAuthSetup(
        file: file,
        seen: _seen(
          route: '/secure-login',
          invalidCredentialVisible: true,
          request: _request(satisfied: false),
        ),
      );
      expect(verdict, AuthSetupFailure.invalidCredential);
    });
  });

  group('case D - the wrong application', () {
    test('an application reporting another identity is an environment '
        'failure', () {
      final verdict = classifyAuthSetup(
        file: file,
        seen: _seen(reportedAppId: 'com.example.other'),
      );
      expect(verdict, AuthSetupFailure.environmentPrerequisite);
    });

    test('an application that reports no identity is not treated as wrong',
        () {
      // A runner that could not read something has learned nothing about
      // it, which is not the same as learning it is wrong - the rule
      // DeviceFacts and E-04's deferred preflight outcome already apply.
      expect(
        classifyAuthSetup(file: file, seen: _seen(reportedAppId: null)),
        isNull,
      );
    });

    test('the Android package is never what the identity is compared '
        'against', () {
      // They are different values by design: `appId` is what the
      // operating system installed, `sdkAppId` is what the application
      // says it is. Comparing them would fail every real run.
      expect(
        classifyAuthSetup(
          file: file,
          seen: _seen(reportedAppId: 'com.example.package'),
        ),
        AuthSetupFailure.environmentPrerequisite,
      );
    });

    test('so is a blocked preflight', () {
      expect(
        classifyAuthSetup(file: file, seen: _seen(environmentBlocked: true)),
        AuthSetupFailure.environmentPrerequisite,
      );
    });
  });

  group('case E - the login UI changed', () {
    test('a missing element stops it', () {
      expect(
        classifyAuthSetup(
          file: file,
          seen: _seen(loginUiMissing: true, route: '/login'),
        ),
        AuthSetupFailure.loginUiNotFound,
      );
    });
  });

  group('case F - authenticated but the route was not reached', () {
    test('/set-location is named rather than called an auth failure', () {
      expect(
        classifyAuthSetup(file: file, seen: _seen(route: '/set-location')),
        AuthSetupFailure.authenticatedStateNotReached,
      );
    });

    test('a route event without a rendered element is not enough', () {
      expect(
        classifyAuthSetup(file: file, seen: _seen(elementPresent: false)),
        AuthSetupFailure.authenticatedStateNotReached,
      );
    });
  });

  group('a one-time-code path', () {
    test('is refused by name rather than timing out', () {
      expect(
        classifyAuthSetup(file: file, seen: _seen(route: '/otp-verification')),
        AuthSetupFailure.authPathNotSupported,
      );
      expect(
        classifyAuthSetup(file: file, seen: _seen(route: '/registration-otp')),
        AuthSetupFailure.authPathNotSupported,
      );
    });
  });

  group('a failed authentication request', () {
    test('is reported when the application showed no error of its own', () {
      expect(
        classifyAuthSetup(
          file: file,
          seen: _seen(route: '/login', request: _request(satisfied: false)),
        ),
        AuthSetupFailure.authRequestFailed,
      );
    });

    test('and when the request never happened at all', () {
      expect(
        classifyAuthSetup(
          file: file,
          seen: _seen(route: '/login', noRequest: true),
        ),
        AuthSetupFailure.authRequestFailed,
      );
    });
  });

  group('precedence - section 9.0, pair by pair', () {
    test('environment outranks a missing secret', () {
      expect(
        classifyAuthSetup(
          file: file,
          seen: _seen(environmentBlocked: true, secretMissing: true),
        ),
        AuthSetupFailure.environmentPrerequisite,
      );
    });

    test('a missing secret outranks a missing login element', () {
      expect(
        classifyAuthSetup(
          file: file,
          seen: _seen(secretMissing: true, loginUiMissing: true),
        ),
        AuthSetupFailure.secretMissing,
      );
    });

    test('a missing login element outranks an unsupported path', () {
      expect(
        classifyAuthSetup(
          file: file,
          seen: _seen(loginUiMissing: true, route: '/otp-verification'),
        ),
        AuthSetupFailure.loginUiNotFound,
      );
    });

    test('an unsupported path outranks an invalid credential', () {
      expect(
        classifyAuthSetup(
          file: file,
          seen: _seen(
            route: '/otp-verification',
            invalidCredentialVisible: true,
          ),
        ),
        AuthSetupFailure.authPathNotSupported,
      );
    });

    test('an invalid credential outranks a failed request', () {
      // "Your PIN is wrong" is actionable. "The login request answered
      // 401" is the same news in a form that sends somebody to a backend.
      expect(
        classifyAuthSetup(
          file: file,
          seen: _seen(
            route: '/secure-login',
            invalidCredentialVisible: true,
            request: _request(satisfied: false),
          ),
        ),
        AuthSetupFailure.invalidCredential,
      );
    });

    test('an invalid credential outranks the stall it caused', () {
      // A rejected credential usually also stalls the flow: the
      // application sits on its own error state and never settles.
      // "That credential was wrong" is the useful sentence.
      expect(
        classifyAuthSetup(
          file: file,
          seen: _seen(
            route: '/secure-login',
            invalidCredentialVisible: true,
            flowFailure: 'the screen did not settle within 30s',
          ),
        ),
        AuthSetupFailure.invalidCredential,
      );
    });

    test('a stalled flow outranks a request that never answered', () {
      // A flow that stalled may never have made the authentication
      // request at all, so reporting the missing request would name a
      // consequence as though it were the cause.
      expect(
        classifyAuthSetup(
          file: file,
          seen: _seen(
            route: '/secure-login',
            noRequest: true,
            flowFailure: 'the screen did not settle within 30s',
          ),
        ),
        AuthSetupFailure.authFlowFailed,
      );
    });

    test('a failed request outranks the route not being reached', () {
      expect(
        classifyAuthSetup(
          file: file,
          seen: _seen(route: '/login', request: _request(satisfied: false)),
        ),
        AuthSetupFailure.authRequestFailed,
      );
    });
  });
}
