import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../api/models.dart';
import '../state/app_state.dart';
import 'artwork.dart';
import 'dialogs.dart';
import 'mini_player.dart';
import 'snack.dart';

/// One screen for the whole download queue.
///
/// A single track behind a spinner needed no screen. A mirrored playlist is a hundred
/// and twenty, and then you need to see how far along it is, what is stuck, and be
/// able to stop it or push one song to the front.
class DownloadsPage extends StatefulWidget {
  const DownloadsPage({super.key});

  @override
  State<DownloadsPage> createState() => _DownloadsPageState();
}

class _DownloadsPageState extends State<DownloadsPage> {
  DownloadOverview? _data;
  Object? _error;
  Timer? _poll;

  @override
  void initState() {
    super.initState();
    _load();
    // Progress arrives over the event stream, but batch counts and the failed list
    // are server-side aggregates; a slow refresh keeps them honest without chatter.
    _poll = Timer.periodic(const Duration(seconds: 5), (_) => _load(quiet: true));
  }

  @override
  void dispose() {
    _poll?.cancel();
    super.dispose();
  }

  Future<void> _load({bool quiet = false}) async {
    try {
      final data = await context.read<AppState>().api.downloads();
      if (!mounted) return;
      setState(() {
        _data = data;
        _error = null;
      });
    } catch (e) {
      if (!mounted || quiet) return;
      setState(() => _error = e);
    }
  }

  Future<void> _act(Future<void> Function() action, String done) async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      await action();
      await _load();
      messenger.showSnackBar(snack(Text(done)));
    } catch (e) {
      messenger.showSnackBar(snack(Text('$e')));
    }
  }

  Future<void> _emptyQueue(int waiting) async {
    final app = context.read<AppState>();
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Cancel everything waiting?'),
        content: Text('$waiting tracks will not be downloaded. Anything already '
            'downloaded stays, and you can add them again later.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Keep them')),
          FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Cancel them')),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    await _act(() => app.api.cancelDownloads(all: true).then((_) {}),
        'Queue emptied');
  }

  @override
  Widget build(BuildContext context) {
    final app = context.read<AppState>();
    final d = _data;

    return PlayerScaffold(
      appBar: AppBar(
        title: const Text('Downloads'),
        actions: [
          if (d != null && (d.waiting > 0 || d.downloading > 0))
            IconButton(
              icon: Icon(d.paused ? Icons.play_arrow : Icons.pause),
              tooltip: d.paused ? 'Resume downloads' : 'Pause downloads',
              onPressed: () => _act(
                  () => app.api.pauseDownloads(!d.paused).then((_) {}),
                  d.paused ? 'Downloads resumed' : 'Downloads paused'),
            ),
          if (d != null && d.waiting > 0)
            PopupMenuButton<String>(
              onSelected: (_) => _emptyQueue(d.waiting),
              itemBuilder: (context) => const [
                PopupMenuItem(value: 'all', child: Text('Cancel everything waiting')),
              ],
            ),
        ],
      ),
      body: _error != null && d == null
          ? ErrorRetry(error: _error!, onRetry: _load)
          : d == null
              ? const Center(child: CircularProgressIndicator())
              : RefreshIndicator(
                  onRefresh: _load,
                  child: ListView(
                    padding: EdgeInsets.only(bottom: bottomForPlayer(context)),
                    children: [
                      _Summary(data: d),
                      if (d.idle)
                        const EmptyHint(
                          icon: Icons.download_done,
                          title: 'Nothing waiting',
                          body: 'Everything you have added is downloaded.',
                        ),
                      if (d.batches.isNotEmpty) ...[
                        _Label(d.batchesTotal > d.batches.length
                            ? 'Imports · ${d.batches.length} of ${d.batchesTotal}'
                            : 'Imports · ${d.batchesTotal}'),
                        for (final b in d.batches) _BatchRow(batch: b, onAct: _act),
                      ],
                      if (d.active.isNotEmpty) ...[
                        _Label('Downloading now · ${d.downloading}'),
                        for (final item in d.active)
                          _ItemRow(item: item, showProgress: true),
                      ],
                      if (d.queued.isNotEmpty) ...[
                        _Label('Waiting · ${d.waiting}'),
                        for (final item in d.queued)
                          _ItemRow(
                            item: item,
                            trailing: PopupMenuButton<String>(
                              icon: const Icon(Icons.more_vert, size: 20),
                              onSelected: (v) => v == 'first'
                                  ? _act(
                                      () => app.api
                                          .promoteDownload(item.track!.id),
                                      'Moved to the front')
                                  : _act(
                                      () => app.api
                                          .cancelDownloads(trackId: item.track!.id)
                                          .then((_) {}),
                                      'Cancelled'),
                              itemBuilder: (context) => const [
                                PopupMenuItem(
                                    value: 'first', child: Text('Download next')),
                                PopupMenuItem(value: 'cancel', child: Text('Cancel')),
                              ],
                            ),
                          ),
                      ],
                      if (d.failures.isNotEmpty) ...[
                        _Label('Failed · ${d.failed}'),
                        Padding(
                          padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                          child: Wrap(
                            spacing: 8,
                            children: [
                              FilledButton.tonalIcon(
                                icon: const Icon(Icons.refresh, size: 18),
                                label: const Text('Try all again'),
                                onPressed: () => _act(
                                    () => app.api
                                        .retryFailedDownloads()
                                        .then((_) {}),
                                    'Retrying'),
                              ),
                              // The song is usually still there under another
                              // upload; a deleted video is not a deleted song.
                              OutlinedButton.icon(
                                icon: const Icon(Icons.travel_explore, size: 18),
                                label: const Text('Look for another copy'),
                                onPressed: () async {
                                  // Captured before the search: it can take a while,
                                  // and a context used afterwards may be gone.
                                  final messenger = ScaffoldMessenger.of(context);
                                  try {
                                    final r = await app.api.refindFailed();
                                    await _load();
                                    messenger.showSnackBar(snack(Text(r['found'] == 0
                                            ? 'Nothing close enough anywhere'
                                            : 'Found ${r['found']} elsewhere — '
                                                'downloading them now')));
                                  } catch (e) {
                                    messenger.showSnackBar(
                                        snack(Text('$e')));
                                  }
                                },
                              ),
                              // Worth separating: these tracks are fine, the
                              // downloader was told to prove it is a person.
                              if (d.failures.any(
                                  (f) => f.track?.failCode == 'bot_check'))
                                OutlinedButton.icon(
                                  icon: const Icon(Icons.shield_outlined, size: 18),
                                  label: const Text('Only the blocked ones'),
                                  onPressed: () => _act(
                                      () => app.api
                                          .retryFailedDownloads(failCode: 'bot_check')
                                          .then((_) {}),
                                      'Retrying the blocked ones'),
                                ),
                            ],
                          ),
                        ),
                        for (final item in d.failures)
                          _ItemRow(
                            item: item,
                            subtitle: item.track?.failReason ?? item.error,
                            isError: true,
                          ),
                      ],
                    ],
                  ),
                ),
    );
  }
}

class _Summary extends StatelessWidget {
  const _Summary({required this.data});
  final DownloadOverview data;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final total = data.outstanding;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                data.paused
                    ? Icons.pause_circle_outline
                    : data.workerOnline
                        ? Icons.cloud_download_outlined
                        : Icons.cloud_off,
                color: data.paused
                    ? scheme.tertiary
                    : data.workerOnline
                        ? scheme.primary
                        : scheme.error,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  data.paused
                      ? 'Paused · $total waiting'
                      : !data.workerOnline
                          ? 'Downloader offline · $total waiting'
                          : total == 0
                              ? 'Up to date'
                              : '$total to download',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
              ),
            ],
          ),
          if (!data.workerOnline && total > 0)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                'Nothing will download until the machine that fetches music is awake.',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
        ],
      ),
    );
  }
}

class _BatchRow extends StatelessWidget {
  const _BatchRow({required this.batch, required this.onAct});
  final DownloadBatch batch;
  final Future<void> Function(Future<void> Function(), String) onAct;

  @override
  Widget build(BuildContext context) {
    final app = context.read<AppState>();
    return ListTile(
      title: Text(batch.label, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SizedBox(height: 4),
          ClipRRect(
            borderRadius: BorderRadius.circular(2),
            child: LinearProgressIndicator(value: batch.fraction, minHeight: 4),
          ),
          const SizedBox(height: 5),
          Text(batch.summary, style: Theme.of(context).textTheme.bodySmall),
        ],
      ),
      trailing: batch.finished
          ? const Icon(Icons.check, size: 20)
          : PopupMenuButton<String>(
              icon: const Icon(Icons.more_vert, size: 20),
              onSelected: (v) => v == 'cancel'
                  ? onAct(
                      () => app.api.cancelDownloads(batchId: batch.id).then((_) {}),
                      'Cancelled ${batch.label}')
                  : onAct(
                      () => app.api
                          .retryFailedDownloads(batchId: batch.id)
                          .then((_) {}),
                      'Retrying ${batch.label}'),
              itemBuilder: (context) => [
                if (batch.failed > 0)
                  const PopupMenuItem(
                      value: 'retry', child: Text('Retry the failed ones')),
                const PopupMenuItem(
                    value: 'cancel', child: Text('Cancel what is left')),
              ],
            ),
    );
  }
}

class _ItemRow extends StatelessWidget {
  const _ItemRow({
    required this.item,
    this.trailing,
    this.subtitle,
    this.showProgress = false,
    this.isError = false,
  });

  final DownloadItem item;
  final Widget? trailing;
  final String? subtitle;
  final bool showProgress;
  final bool isError;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final track = item.track;
    return ListTile(
      leading: track == null
          ? const Icon(Icons.music_note)
          : Artwork(track: track, size: 40),
      title: Text(track?.displayTitle ?? 'Unknown track',
          maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(subtitle ?? item.line,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: isError ? TextStyle(color: scheme.error) : null),
          if (showProgress) ...[
            const SizedBox(height: 5),
            ClipRRect(
              borderRadius: BorderRadius.circular(2),
              child: LinearProgressIndicator(value: item.fraction, minHeight: 3),
            ),
          ],
          if (item.batchLabel != null)
            Padding(
              padding: const EdgeInsets.only(top: 3),
              child: Text(item.batchLabel!,
                  style: Theme.of(context).textTheme.labelSmall?.copyWith(
                      color: scheme.onSurfaceVariant)),
            ),
        ],
      ),
      trailing: trailing,
    );
  }
}

class _Label extends StatelessWidget {
  const _Label(this.text);
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 18, 16, 4),
        child: Text(text.toUpperCase(),
            style: Theme.of(context).textTheme.labelSmall?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant)),
      );
}
