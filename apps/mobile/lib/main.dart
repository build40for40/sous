import 'dart:async';

import 'package:flutter/material.dart';

import 'auth/auth_controller.dart';
import 'services.dart';
import 'shares/share_receiver.dart';
import 'ui/flame.dart';
import 'ui/home.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  final services = SousServices();
  unawaited(services.auth.restore());
  unawaited(services.startSharing(SystemShareReceiver()));
  runApp(MainApp(services: services));
}

class MainApp extends StatelessWidget {
  const MainApp({super.key, required this.services});

  final SousServices services;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Sous',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        brightness: Brightness.dark,
        fontFamily: 'Inter',
        scaffoldBackgroundColor: Colors.black,
        colorScheme: const ColorScheme.dark(
          primary: Color(0xFF6FA8FF),
          surface: Colors.black,
        ),
      ),
      home: StreamBuilder<AuthState>(
        stream: services.auth.states,
        initialData: services.auth.state,
        builder: (context, snap) => switch (snap.data) {
          SignedIn() => Home(services: services),
          AuthRestoring() || null => const Scaffold(),
          final state => SignIn(
            busy: state is SigningIn,
            failed: state is SignedOut && state.error != null,
            onSignIn: () => unawaited(services.auth.signIn()),
          ),
        },
      ),
    );
  }
}

/// The first screen: the burner, the name, and one button.
class SignIn extends StatelessWidget {
  const SignIn({
    super.key,
    required this.busy,
    required this.failed,
    required this.onSignIn,
  });

  final bool busy;
  final bool failed;
  final VoidCallback onSignIn;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 24),
          child: Column(
            children: [
              const Expanded(child: Flame()),
              const Text(
                'Sous',
                style: TextStyle(
                  fontSize: 40,
                  fontWeight: FontWeight.w700,
                  letterSpacing: -.8,
                ),
              ),
              const SizedBox(height: 8),
              const Text(
                'Your sous chef. Hands on the food, not the phone.',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 16, color: Color(0xFF7C7C80)),
              ),
              if (failed) ...[
                const SizedBox(height: 12),
                const Text(
                  'That didn’t work. Try again.',
                  style: TextStyle(color: Color(0xFFFF8C7A)),
                ),
              ],
              const SizedBox(height: 28),
              SizedBox(
                width: double.infinity,
                height: 54,
                child: FilledButton(
                  onPressed: busy ? null : onSignIn,
                  style: FilledButton.styleFrom(
                    backgroundColor: const Color(0xFFF5F5F7),
                    foregroundColor: Colors.black,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(16),
                    ),
                  ),
                  child: Text(
                    busy ? 'Signing in…' : 'Sign in',
                    style: const TextStyle(
                      fontSize: 17,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
