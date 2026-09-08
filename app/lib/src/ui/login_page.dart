import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../state/app_state.dart';

class LoginPage extends StatefulWidget {
  const LoginPage({super.key});

  @override
  State<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends State<LoginPage> {
  final _server = TextEditingController(text: AppState.defaultServer);
  final _user = TextEditingController();
  final _pass = TextEditingController();
  final _code = TextEditingController();
  bool _busy = false;
  bool _joining = false;      // redeeming an invite rather than signing in
  bool _showPassword = false;
  bool _showServer = false;

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    return Scaffold(
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text('Muse',
                    style: Theme.of(context)
                        .textTheme
                        .headlineSmall
                        ?.copyWith(fontSize: 40, fontWeight: FontWeight.w800)),
                const SizedBox(height: 4),
                Text('Sign in to your server',
                    style: Theme.of(context).textTheme.bodyMedium),
                const SizedBox(height: 24),
                // The server is right by construction on web, and typed once on a
                // phone. Hiding it keeps the common case to two fields.
                if (_showServer) ...[
                  TextField(
                    controller: _server,
                    decoration: const InputDecoration(
                        labelText: 'Server', prefixIcon: Icon(Icons.dns_outlined)),
                    keyboardType: TextInputType.url,
                  ),
                  const SizedBox(height: 12),
                ],
                if (_joining) ...[
                  TextField(
                    controller: _code,
                    decoration: const InputDecoration(
                      labelText: 'Invite code',
                      prefixIcon: Icon(Icons.key),
                      helperText: 'From someone who already has an account',
                    ),
                  ),
                  const SizedBox(height: 12),
                ],
                TextField(
                  controller: _user,
                  autofillHints: const [AutofillHints.username],
                  decoration: const InputDecoration(
                      labelText: 'User', prefixIcon: Icon(Icons.person_outline)),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _pass,
                  obscureText: !_showPassword,
                  autofillHints: [
                    _joining ? AutofillHints.newPassword : AutofillHints.password
                  ],
                  onSubmitted: (_) => _submit(),
                  decoration: InputDecoration(
                    labelText: _joining ? 'Choose a password' : 'Password',
                    helperText: _joining ? 'At least 8 characters' : null,
                    prefixIcon: const Icon(Icons.lock_outline),
                    // Generated passwords on a phone keyboard are miserable without
                    // a way to check what you typed.
                    suffixIcon: IconButton(
                      icon: Icon(_showPassword
                          ? Icons.visibility_off_outlined
                          : Icons.visibility_outlined),
                      tooltip: _showPassword ? 'Hide password' : 'Show password',
                      onPressed: () =>
                          setState(() => _showPassword = !_showPassword),
                    ),
                  ),
                ),
                if (app.error != null) ...[
                  const SizedBox(height: 16),
                  Text(app.error!,
                      style: TextStyle(color: Theme.of(context).colorScheme.error)),
                ],
                const SizedBox(height: 24),
                FilledButton(
                  onPressed: _busy ? null : _submit,
                  child: _busy
                      ? const SizedBox(
                          height: 18,
                          width: 18,
                          child: CircularProgressIndicator(strokeWidth: 2))
                      : Text(_joining ? 'Join' : 'Sign in'),
                ),
                const SizedBox(height: 6),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    TextButton(
                      onPressed: () => setState(() {
                        _joining = !_joining;
                        _code.clear();
                      }),
                      child: Text(_joining
                          ? 'I already have an account'
                          : 'I have an invite code'),
                    ),
                    TextButton(
                      onPressed: () => setState(() => _showServer = !_showServer),
                      child: Text(_showServer ? 'Hide server' : 'Change server'),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _submit() async {
    final app = context.read<AppState>();
    if (_user.text.trim().isEmpty || _pass.text.isEmpty) {
      app.reportError(_joining
          ? 'Pick a name and a password'
          : 'Enter your user name and password');
      return;
    }
    if (_joining && _code.text.trim().isEmpty) {
      app.reportError('Enter the invite code you were given');
      return;
    }
    setState(() => _busy = true);
    if (_joining) {
      await app.redeem(
          _server.text.trim(), _code.text, _user.text.trim(), _pass.text);
    } else {
      await app.login(_server.text.trim(), _user.text.trim(), _pass.text);
    }
    if (mounted) setState(() => _busy = false);
  }

  @override
  void dispose() {
    _server.dispose();
    _user.dispose();
    _pass.dispose();
    _code.dispose();
    super.dispose();
  }
}
