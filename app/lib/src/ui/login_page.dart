import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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
  final _passFocus = FocusNode();

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    return Scaffold(
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: SingleChildScrollView(
            // Scrolls rather than overflowing when the keyboard takes half a phone.
            padding: const EdgeInsets.all(24),
            // One group, so a password manager offers the saved sign-in and offers to
            // save a new one — without it the two fields were strangers to each other.
            child: AutofillGroup(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // The owl, from the server that is about to be signed in to. A
                // wordmark on its own read as a placeholder.
                // Its room is kept while it loads — a centred form that jumps down
                // when a picture arrives is a form that moves under the finger — and
                // a server that cannot be reached gets a stand-in, not a hole.
                Align(
                  alignment: Alignment.centerLeft,
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(16),
                    child: SizedBox(
                      width: 64,
                      height: 64,
                      child: Image.network(
                        app.api.appIconUrl(size: 192),
                        fit: BoxFit.cover,
                        frameBuilder: (context, child, frame, sync) =>
                            sync || frame != null ? child : const _IconStandIn(),
                        errorBuilder: (_, __, ___) => const _IconStandIn(),
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 14),
                Text('WetOwl',
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
                        labelText: 'Server',
                        helperText: 'The address, with or without https://',
                        prefixIcon: Icon(Icons.dns_outlined)),
                    keyboardType: TextInputType.url,
                    autocorrect: false,
                    textInputAction: TextInputAction.next,
                  ),
                  const SizedBox(height: 12),
                ],
                if (_joining) ...[
                  TextField(
                    controller: _code,
                    autocorrect: false,
                    textInputAction: TextInputAction.next,
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
                  autofillHints: [
                    _joining ? AutofillHints.newUsername : AutofillHints.username
                  ],
                  autocorrect: false,
                  textInputAction: TextInputAction.next,
                  // Return goes to the password rather than nowhere.
                  onSubmitted: (_) => _passFocus.requestFocus(),
                  decoration: const InputDecoration(
                      labelText: 'User', prefixIcon: Icon(Icons.person_outline)),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _pass,
                  focusNode: _passFocus,
                  textInputAction: TextInputAction.go,
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
                      onPressed: () {
                        // The complaint about the other form does not belong to this one.
                        app.clearError();
                        setState(() {
                          _joining = !_joining;
                          _code.clear();
                        });
                      },
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
    final ok = _joining
        ? await app.redeem(
            _server.text.trim(), _code.text, _user.text.trim(), _pass.text)
        : await app.login(_server.text.trim(), _user.text.trim(), _pass.text);
    // Tells a password manager the sign-in worked, which is when it offers to save it.
    if (ok) TextInput.finishAutofillContext();
    if (mounted) setState(() => _busy = false);
  }

  @override
  void dispose() {
    _server.dispose();
    _user.dispose();
    _pass.dispose();
    _code.dispose();
    _passFocus.dispose();
    super.dispose();
  }
}

/// The shape of the icon, in the app's own colours, until the real one is here.
class _IconStandIn extends StatelessWidget {
  const _IconStandIn();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ColoredBox(
      color: scheme.primary.withValues(alpha: 0.16),
      child: Icon(Icons.graphic_eq, color: scheme.primary, size: 30),
    );
  }
}
