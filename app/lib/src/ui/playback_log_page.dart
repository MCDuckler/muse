import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../state/playback_log.dart';
import 'snack.dart';

/// What the audio engine did, in order.
///
/// Here because "it stops after a while when I switch away" cannot be watched
/// happening: the interesting minute is always the one with the screen off. This is
/// the app's own account of it, kept across restarts — so the line before a restart
/// says whether the app stopped or was stopped.
class PlaybackLogPage extends StatefulWidget {
  const PlaybackLogPage({super.key});

  @override
  State<PlaybackLogPage> createState() => _PlaybackLogPageState();
}

class _PlaybackLogPageState extends State<PlaybackLogPage> {
  @override
  Widget build(BuildContext context) {
    final lines = PlaybackLog.lines.reversed.toList();
    final text = Theme.of(context).textTheme;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Playback log'),
        actions: [
          IconButton(
            icon: const Icon(Icons.copy_all_outlined),
            tooltip: 'Copy',
            onPressed: () async {
              await Clipboard.setData(ClipboardData(text: PlaybackLog.text));
              if (!context.mounted) return;
              ScaffoldMessenger.of(context)
                  .showSnackBar(snack(Text('Log copied')));
            },
          ),
          IconButton(
            icon: const Icon(Icons.delete_outline),
            tooltip: 'Clear',
            onPressed: () async {
              await PlaybackLog.clear();
              if (mounted) setState(() {});
            },
          ),
        ],
      ),
      body: lines.isEmpty
          ? const Center(child: Text('Nothing recorded yet.'))
          : ListView.builder(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
              itemCount: lines.length,
              itemBuilder: (context, i) => Padding(
                padding: const EdgeInsets.symmetric(vertical: 3),
                child: Text(
                  lines[i],
                  style: text.bodySmall?.copyWith(
                      fontFamily: 'monospace',
                      color: lines[i].contains('---')
                          ? Theme.of(context).colorScheme.primary
                          : lines[i].contains('error') ||
                                  lines[i].contains('gave up')
                              ? Theme.of(context).colorScheme.error
                              : null),
                ),
              ),
            ),
    );
  }
}
