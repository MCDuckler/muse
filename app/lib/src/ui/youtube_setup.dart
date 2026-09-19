import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../state/app_state.dart';
import 'snack.dart';

/// Turning on the sign-in that actually works.
///
/// Google will not let anybody sign in inside an app's own browser: an embedded one is
/// answered with "this browser or app may not be secure", and no user agent gets around
/// it, because that is exactly what the check is for. The way in Google *does* support
/// for something without a browser of its own is the device flow — the app shows a
/// short code, somebody types it into a browser they already trust, and the sign-in
/// comes back here. It also lasts, where a copied cookie expires in a fortnight.
///
/// It needs one thing: an OAuth client of the "TV and Limited Input" kind, which is a
/// two-minute job in Google's console and is done once for the whole server. This is
/// where that is pasted in, so nobody has to edit a file on the box to do it.
///
/// Answers true when the server took one, so the caller can reload and find the code
/// sign-in waiting where the paste box used to be.
Future<bool> youtubeCodeSignInSetup(BuildContext context) async {
  final api = context.read<AppState>().api;
  final messenger = ScaffoldMessenger.of(context);

  // Only an admin can set this, and only an admin should be shown it: for everybody
  // else the answer to "why can I not sign in" is "ask whoever runs this".
  try {
    final client = await api.youtubeSignInClient();
    if (!client.maySet) {
      messenger.say(snack(const Text(
          'Signing in with a code has to be switched on by whoever runs this '
          'server.')));
      return false;
    }
  } catch (_) {
    // An older server, or one that cannot be asked. The paste box is still there.
    return false;
  }
  if (!context.mounted) return false;

  final id = TextEditingController();
  final secret = TextEditingController();
  var busy = false;

  final done = await showDialog<bool>(
    context: context,
    builder: (context) => StatefulBuilder(
      builder: (context, refresh) => AlertDialog(
        title: const Text('Sign in to YouTube with a code'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Google refuses to sign anyone in inside an app, so WetOwl asks for a '
                'code instead — you type it into a browser you already use. That needs '
                'one credential from Google, once, for this whole server:',
              ),
              const SizedBox(height: 12),
              const _Steps([
                'Open console.cloud.google.com and make a project (any name).',
                'APIs & Services → Library → YouTube Data API v3 → Enable. '
                    'This is what reads the library.',
                'Google Auth Platform → set it up as External.',
                'Audience → Publish app. Left in Testing it only works for '
                    'accounts listed on it one by one, which is Google turning '
                    'everybody else away.',
                'Clients → Create client (or Credentials → Create credentials → '
                    'OAuth client ID).',
                'Application type: TV and Limited Input devices.',
                'Copy the client ID and client secret it gives you into the boxes '
                    'below.',
              ]),
              const SizedBox(height: 6),
              const Text(
                'Published without going through Google\'s review, the sign-in page '
                'says the app is unverified and offers Advanced → Go to app. That is '
                'expected, and it is your own server.',
              ),
              const SizedBox(height: 8),
              TextField(
                controller: id,
                autofocus: true,
                decoration: const InputDecoration(
                  labelText: 'Client ID',
                  hintText: '…apps.googleusercontent.com',
                ),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: secret,
                decoration: const InputDecoration(labelText: 'Client secret'),
              ),
              const SizedBox(height: 10),
              Text(
                'Checked with Google before it is kept, and never shown again — a '
                'credential that goes in does not come back out.',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: busy ? null : () => Navigator.of(context).pop(false),
            child: const Text('Not now'),
          ),
          FilledButton(
            onPressed: busy
                ? null
                : () async {
                    refresh(() => busy = true);
                    try {
                      await api.setYoutubeSignInClient(
                          id.text.trim(), secret.text.trim());
                      if (context.mounted) Navigator.of(context).pop(true);
                    } catch (e) {
                      refresh(() => busy = false);
                      messenger.say(snack(Text('$e')));
                    }
                  },
            child: busy
                ? const SizedBox(
                    width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                : const Text('Save'),
          ),
        ],
      ),
    ),
  );

  id.dispose();
  secret.dispose();
  if (done == true) {
    messenger.say(snack(
        const Text('Done — signing in is a code now, for everybody on this server.')));
  }
  return done == true;
}

/// A numbered list that reads like instructions rather than a paragraph with full
/// stops in it.
class _Steps extends StatelessWidget {
  const _Steps(this.steps);
  final List<String> steps;

  @override
  Widget build(BuildContext context) {
    final style = Theme.of(context).textTheme.bodySmall;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (var i = 0; i < steps.length; i++)
          Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(
                    width: 20, child: Text('${i + 1}.', style: style)),
                Expanded(child: Text(steps[i], style: style)),
              ],
            ),
          ),
      ],
    );
  }
}

/// What somebody reads out, while they are reading it out.
///
/// Kept as its own widget because the code is the whole of this screen: it is large,
/// it is selectable, and it can be copied — a short code typed wrong on another device
/// is the one way this flow goes round again.
class SignInCode extends StatelessWidget {
  const SignInCode({super.key, required this.code});
  final String code;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: () {
        Clipboard.setData(ClipboardData(text: code));
        ScaffoldMessenger.of(context)
            .say(snack(const Text('Code copied')));
      },
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        decoration: BoxDecoration(
          color: scheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            SelectableText(
              code,
              style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                  letterSpacing: 4, fontFeatures: const [FontFeature.tabularFigures()]),
            ),
            const SizedBox(width: 10),
            Icon(Icons.copy, size: 18, color: scheme.onSurfaceVariant),
          ],
        ),
      ),
    );
  }
}
