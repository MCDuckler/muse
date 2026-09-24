import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../api/models.dart';
import '../state/app_state.dart';
import 'artwork.dart';
import 'dialogs.dart';
import 'mini_player.dart';
import 'parts_jobs_section.dart';
import 'snack.dart';
import 'skeleton.dart';
import 'record_refresh.dart';
import '../worker/this_computer.dart' show thisComputerCard;

/// The pool: every computer in the house fetching songs and taking records apart for
/// everybody (server/muse/pool.py), on one screen.
///
/// From the top: this computer's part in it and its switches; what every computer is
/// doing right now; what is waiting, of both kinds; the computers themselves — which
/// are working, which has a graphics card, what each has done today, and for an admin
/// the switch that keeps one out; this computer's own booth splits; then the imports
/// and what failed. Named DownloadsPage still, because everything that opened the old
/// downloads screen opens this.
class DownloadsPage extends StatefulWidget {
  const DownloadsPage({super.key});

  @override
  State<DownloadsPage> createState() => _DownloadsPageState();
}

class _DownloadsPageState extends State<DownloadsPage> {
  DownloadOverview? _data;
  Map<String, dynamic>? _pool;
  Object? _error;
  Timer? _poll;

  @override
  void initState() {
    super.initState();
    _load();
    // Progress arrives over the event stream, but the pool and the batch counts are
    // server-side aggregates; a steady refresh keeps them honest without chatter.
    _poll = Timer.periodic(const Duration(seconds: 3), (_) => _load(quiet: true));
  }

  @override
  void dispose() {
    _poll?.cancel();
    super.dispose();
  }

  Future<void> _load({bool quiet = false}) async {
    final api = context.read<AppState>().api;
    try {
      final got = await Future.wait([api.downloads(), api.pool()]);
      if (!mounted) return;
      setState(() {
        _data = got[0] as DownloadOverview;
        _pool = got[1] as Map<String, dynamic>;
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
      messenger.say(snack(Text(done)));
    } catch (e) {
      messenger.say(snack(Text('$e')));
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
    final pool = _pool;
    final admin = pool?['admin'] == true;
    final paused = (pool?['paused'] as Map?) ?? const {};

    return PlayerScaffold(
      appBar: AppBar(
        title: const Text('Pool'),
        actions: [
          if (admin)
            PopupMenuButton<String>(
              tooltip: 'Pause',
              icon: Icon(paused.values.any((v) => v == true)
                  ? Icons.pause_circle
                  : Icons.pause_circle_outline),
              onSelected: (kind) {
                final now = paused[kind] == true;
                _act(() => app.api.poolPause(kind, !now),
                    '${kind == 'split' ? 'Splitting' : 'Fetching'} ${now ? 'resumed' : 'paused'}');
              },
              itemBuilder: (context) => [
                CheckedPopupMenuItem(
                    value: 'ingest',
                    checked: paused['ingest'] == true,
                    child: const Text('Fetching paused')),
                CheckedPopupMenuItem(
                    value: 'split',
                    checked: paused['split'] == true,
                    child: const Text('Splitting paused')),
              ],
            ),
          if (d != null && d.waiting > 0)
            PopupMenuButton<String>(
              onSelected: (_) => _emptyQueue(d.waiting),
              itemBuilder: (context) => const [
                PopupMenuItem(value: 'all', child: Text('Cancel every waiting download')),
              ],
            ),
        ],
      ),
      body: _error != null && d == null
          ? ErrorRetry(error: _error!, onRetry: _load)
          : d == null || pool == null
              ? const SongsComing()
              : RecordRefresh(
                  onRefresh: _load,
                  child: ListView(
                    padding: EdgeInsets.only(bottom: bottomForPlayer(context)),
                    children: [
                      _PoolSummary(pool: pool),
                      thisComputerCard(),
                      ..._working(pool),
                      ..._waiting(pool, app),
                      _Computers(pool: pool, onAct: _act),
                      // The booth's own records being taken apart on this computer.
                      const PartsJobsSection(),
                      if (d.batches.isNotEmpty) ...[
                        _Label(d.batchesTotal > d.batches.length
                            ? 'Imports · ${d.batches.length} of ${d.batchesTotal}'
                            : 'Imports · ${d.batchesTotal}'),
                        for (final b in d.batches) _BatchRow(batch: b, onAct: _act),
                      ],
                      ..._failedSplits(pool, app),
                      if (d.failures.isNotEmpty) ..._failures(d, app),
                    ],
                  ),
                ),
    );
  }

  List<Widget> _working(Map<String, dynamic> pool) {
    final active = [for (final a in (pool['active'] as List? ?? const [])) a as Map];
    if (active.isEmpty) return const [];
    return [
      _Label('Working now · ${active.length}'),
      for (final a in active) _PoolJobRow(job: a, working: true),
    ];
  }

  List<Widget> _waiting(Map<String, dynamic> pool, AppState app) {
    final waiting = [for (final a in (pool['waiting'] as List? ?? const [])) a as Map];
    if (waiting.isEmpty) return const [];
    final counts = (pool['counts'] as Map?) ?? const {};
    int n(String kind) => ((counts[kind] as Map?)?['pending'] as num?)?.toInt() ?? 0;
    return [
      _Label('Waiting · ${n('ingest')} to fetch · ${n('split')} to take apart'),
      for (final w in waiting)
        _PoolJobRow(
          job: w,
          trailing: PopupMenuButton<String>(
            icon: const Icon(Icons.more_vert, size: 20),
            onSelected: (v) {
              final trackId = w['track_id'] as int?;
              if (v == 'first' && trackId != null) {
                _act(() => app.api.promoteDownload(trackId), 'Moved to the front');
              } else if (v == 'cancel' && w['kind'] == 'split') {
                _act(() => app.api.poolCancel(w['job_id'] as int), 'Taken off the list');
              } else if (v == 'cancel' && trackId != null) {
                _act(() => app.api.cancelDownloads(trackId: trackId).then((_) {}), 'Cancelled');
              }
            },
            itemBuilder: (context) => [
              if (w['kind'] == 'ingest')
                const PopupMenuItem(value: 'first', child: Text('Fetch next')),
              const PopupMenuItem(value: 'cancel', child: Text('Cancel')),
            ],
          ),
        ),
    ];
  }

  List<Widget> _failedSplits(Map<String, dynamic> pool, AppState app) {
    final failed = [for (final a in (pool['failed_splits'] as List? ?? const [])) a as Map];
    if (failed.isEmpty) return const [];
    return [
      _Label('Could not take apart · ${failed.length}'),
      for (final f in failed)
        _PoolJobRow(
          job: f,
          error: '${f['error'] ?? 'failed'}',
          trailing: IconButton(
            tooltip: 'Try again',
            icon: const Icon(Icons.refresh),
            onPressed: () => _act(() => app.api.poolRetry(f['job_id'] as int), 'Trying again'),
          ),
        ),
    ];
  }

  List<Widget> _failures(DownloadOverview d, AppState app) => [
        _Label('Could not fetch · ${d.failed}'),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
          child: Wrap(
            spacing: 8,
            children: [
              FilledButton.tonalIcon(
                icon: const Icon(Icons.refresh, size: 18),
                label: const Text('Try all again'),
                onPressed: () => _act(
                    () => app.api.retryFailedDownloads().then((_) {}), 'Retrying'),
              ),
              // The song is usually still there under another upload; a deleted video
              // is not a deleted song.
              OutlinedButton.icon(
                icon: const Icon(Icons.travel_explore, size: 18),
                label: const Text('Look for another copy'),
                onPressed: () async {
                  final messenger = ScaffoldMessenger.of(context);
                  try {
                    final r = await app.api.refindFailed();
                    await _load();
                    messenger.say(snack(Text(r['found'] == 0
                        ? 'Nothing close enough anywhere'
                        : 'Found ${r['found']} elsewhere — fetching them now')));
                  } catch (e) {
                    messenger.say(snack(Text('$e')));
                  }
                },
              ),
              if (d.failures.any((f) => f.track?.failCode == 'bot_check'))
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
      ];
}

/// The pool at a glance: how many computers are working and what is left.
class _PoolSummary extends StatelessWidget {
  const _PoolSummary({required this.pool});
  final Map<String, dynamic> pool;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final devices = [for (final d in (pool['devices'] as List? ?? const [])) d as Map];
    final live = devices.where((d) => d['live'] == true).toList();
    final cards = live.where((d) => d['gpu'] == true && d['split'] == true).length;
    final counts = (pool['counts'] as Map?) ?? const {};
    int n(String kind, String state) =>
        ((counts[kind] as Map?)?[state] as num?)?.toInt() ?? 0;
    final paused = (pool['paused'] as Map?) ?? const {};
    final nobody = live.isEmpty;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            Icon(nobody ? Icons.cloud_off : Icons.hub_outlined,
                color: nobody ? scheme.error : scheme.primary),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                nobody
                    ? 'No computer is working for the pool'
                    : '${live.length} ${live.length == 1 ? 'computer' : 'computers'} working'
                        '${cards > 0 ? ' · $cards with a graphics card' : ''}',
                style: Theme.of(context).textTheme.titleMedium,
              ),
            ),
          ]),
          const SizedBox(height: 4),
          Text(
            [
              '${n('ingest', 'leased')} fetching · ${n('ingest', 'pending')} to fetch'
                  '${paused['ingest'] == true ? ' (paused)' : ''}',
              '${n('split', 'leased')} taking apart · ${n('split', 'pending')} to take apart'
                  '${paused['split'] == true ? ' (paused)' : ''}',
              '${pool['parts_kept'] ?? 0} records kept in parts',
            ].join('  ·  '),
            style: Theme.of(context).textTheme.bodySmall,
          ),
          if (nobody && n('ingest', 'pending') + n('split', 'pending') > 0)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                  'Nothing is fetched or taken apart until a desktop with WetOwl open '
                  '(or working in the background) is about.',
                  style: Theme.of(context).textTheme.bodySmall),
            ),
        ],
      ),
    );
  }
}

/// One job in the pool: a song to fetch or a record to take apart, whose it is, and
/// how far it has got.
class _PoolJobRow extends StatelessWidget {
  const _PoolJobRow({required this.job, this.working = false, this.trailing, this.error});
  final Map job;
  final bool working;
  final Widget? trailing;
  final String? error;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final t = job['track'] is Map
        ? Track.fromJson(Map<String, dynamic>.from(job['track'] as Map))
        : null;
    final split = job['kind'] == 'split';
    final pr = job['progress'] as Map?;
    final pct = (pr?['percent'] as num?)?.toDouble();
    final who = job['device'] as String?;
    final line = error ??
        [
          split ? 'Take apart' : 'Fetch',
          if (working && who != null) 'on $who',
          if (working && pr != null) '${pr['label'] ?? pr['stage'] ?? ''}',
          if (working && pct != null) '${(pct * 100).floor()}%',
          if (!working && (job['priority'] as num? ?? 100) <= 10) 'somebody is waiting',
          if (job['batch_label'] != null) '${job['batch_label']}',
        ].where((x) => x.isNotEmpty).join(' · ');
    return ListTile(
      leading: Stack(clipBehavior: Clip.none, children: [
        t == null ? const Icon(Icons.music_note) : Artwork(track: t, size: 40),
        Positioned(
          right: -4,
          bottom: -4,
          child: Container(
            padding: const EdgeInsets.all(2),
            color: scheme.surface,
            child: Icon(split ? Icons.call_split : Icons.download,
                size: 14, color: scheme.primary),
          ),
        ),
      ]),
      title: Text(t?.displayTitle ?? 'Track ${job['track_id']}',
          maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(line,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: error != null ? TextStyle(color: scheme.error) : null),
          if (working) ...[
            const SizedBox(height: 5),
            ClipRRect(
              borderRadius: BorderRadius.circular(2),
              child: LinearProgressIndicator(value: pct, minHeight: 3),
            ),
          ],
        ],
      ),
      trailing: trailing,
    );
  }
}

/// The computers in the pool: which are working, what each does and has done today,
/// which has a graphics card. For an admin, the switch that keeps one out.
class _Computers extends StatelessWidget {
  const _Computers({required this.pool, required this.onAct});
  final Map<String, dynamic> pool;
  final Future<void> Function(Future<void> Function(), String) onAct;

  @override
  Widget build(BuildContext context) {
    final api = context.read<AppState>().api;
    final scheme = Theme.of(context).colorScheme;
    final admin = pool['admin'] == true;
    final devices = [for (final d in (pool['devices'] as List? ?? const [])) d as Map];
    if (devices.isEmpty) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _Label('Computers · ${devices.where((d) => d['live'] == true).length} working'),
        for (final d in devices)
          ListTile(
            leading: Icon(
              d['platform'] == 'windows' ? Icons.desktop_windows_outlined : Icons.computer,
              color: d['live'] == true ? scheme.primary : scheme.onSurfaceVariant,
            ),
            title: Row(children: [
              Flexible(
                child: Text('${d['name']}${d['this'] == true ? ' (this one)' : ''}',
                    maxLines: 1, overflow: TextOverflow.ellipsis),
              ),
              if (d['gpu'] == true) ...[
                const SizedBox(width: 6),
                Icon(Icons.memory, size: 16, color: scheme.primary),
              ],
            ]),
            subtitle: Text([
              '${d['owner']}',
              if (d['blocked'] == true)
                'kept out'
              else if (d['live'] == true)
                [
                  if (d['fetch'] == true) 'fetches',
                  if (d['split'] == true) 'takes apart',
                  if ((d['busy'] as num? ?? 0) > 0) 'busy with ${d['busy']}',
                ].join(', ')
              else
                'not working now',
              if (d['background'] == true) 'in the background',
              if ((d['fetched_today'] as num? ?? 0) > 0) '${d['fetched_today']} fetched today',
              if ((d['split_today'] as num? ?? 0) > 0) '${d['split_today']} taken apart today',
            ].where((x) => x.isNotEmpty).join(' · ')),
            trailing: admin
                ? Switch(
                    value: d['blocked'] != true,
                    onChanged: (on) => onAct(
                        () => api.poolBlock(d['id'] as int, !on),
                        on ? 'Back in the pool' : 'Kept out of the pool'),
                  )
                : null,
          ),
      ],
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
    this.subtitle,
    this.isError = false,
  });

  final DownloadItem item;
  final String? subtitle;
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
          if (item.batchLabel != null)
            Padding(
              padding: const EdgeInsets.only(top: 3),
              child: Text(item.batchLabel!,
                  style: Theme.of(context).textTheme.labelSmall?.copyWith(
                      color: scheme.onSurfaceVariant)),
            ),
        ],
      ),
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
