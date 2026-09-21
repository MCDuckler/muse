import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../api/client.dart';
import '../state/app_state.dart';
import '../ui/mag.dart';
import '../ui/mag_parts.dart';
import '../ui/mini_player.dart';
import '../ui/snack.dart';
import 'downloader.dart';
import 'tools.dart';

/// Only on a desk. A phone could run the loop but not the programs, and should not be
/// spending its battery and its data on somebody else's playlist.
bool get canFetchMusicHere =>
    defaultTargetPlatform == TargetPlatform.linux ||
    defaultTargetPlatform == TargetPlatform.windows ||
    defaultTargetPlatform == TargetPlatform.macOS;

const _kWanted = 'muse.fetchHere';
const _kSlots = 'muse.fetchHere.slots';

Downloader? _downloader;
ApiClient? _api;
RandomAccessFile? _lock;

/// The server, spoken to with the token this device already signs in with.
class _AppServer implements IngestServer {
  _AppServer(this.api);
  final ApiClient api;

  @override
  Future<List<IngestJob>> lease(
      {required int limit, required int busy, bool urgentOnly = false, int wait = 0}) async {
    try {
      final d = await api.workerPost(
          '/internal/jobs/lease',
          {
            'kind': 'ingest',
            'limit': limit,
            'busy': busy,
            'wait': wait,
            if (urgentOnly) 'max_priority': 90,
          },
          timeout: Duration(seconds: wait + 15));
      return [
        for (final j in (d['jobs'] ?? const []) as List)
          if (IngestJob.fromJson((j as Map).cast<String, dynamic>()) case final job?) job
      ];
    } on ApiException catch (e) {
      // Not allowed, or no longer: there is nothing to be gained by asking again.
      if (e.status == 403 || e.status == 401) throw IngestRefused(e.message);
      rethrow;
    }
  }

  @override
  Future<void> progress(IngestJob job, String stage, {double? percent, String? speed}) =>
      api.workerPost('/internal/jobs/${job.id}/progress',
          {'track_id': job.trackId, 'stage': stage, 'percent': percent, 'speed': speed},
          timeout: const Duration(seconds: 10));

  @override
  Future<void> fail(IngestJob job, String reason, {required bool retryable}) =>
      api.workerPost('/internal/jobs/${job.id}/fail', {
        'reason': reason.length > 500 ? reason.substring(0, 500) : reason,
        'retryable': retryable,
        'track_id': job.trackId,
      });

  @override
  Future<void> release(IngestJob job) =>
      api.workerPost('/internal/jobs/${job.id}/release', {'track_id': job.trackId},
          timeout: const Duration(seconds: 10));

  @override
  Future<void> complete(IngestJob job, File audio, Map<String, dynamic> meta) async {
    final request = http.MultipartRequest(
        'POST', Uri.parse('${api.baseUrl}/internal/jobs/${job.id}/complete'))
      ..headers.addAll({if (api.token != null) 'Authorization': 'Bearer ${api.token}'})
      ..fields['meta'] = jsonEncode(meta)
      // From the file, not from memory: an hour-long set is sixty megabytes.
      ..files.add(await http.MultipartFile.fromPath('audio', audio.path,
          filename: audio.uri.pathSegments.last));
    final response = await http.Response.fromStream(
        await request.send().timeout(const Duration(minutes: 5)));
    if (response.statusCode >= 300) {
      throw ApiException(response.statusCode, response.body);
    }
  }

}

Future<Directory> _toolsDir() async {
  final base = await getApplicationSupportDirectory();
  return Directory('${base.path}${Platform.pathSeparator}tools');
}

/// One of these to a computer. Two copies of the app both fetching is twice the requests
/// from one connection, and YouTube counts.
Future<bool> _takeTheLock() async {
  if (_lock != null) return true;
  try {
    final base = await getApplicationSupportDirectory();
    await base.create(recursive: true);
    final f = await File('${base.path}${Platform.pathSeparator}fetching.lock')
        .open(mode: FileMode.append);
    await f.lock(FileLock.exclusive);
    _lock = f;
    return true;
  } catch (_) {
    return false;
  }
}

Downloader _downloaderFor(AppState app) {
  if (_downloader != null && identical(_api, app.api)) return _downloader!;
  _downloader?.dispose();
  _api = app.api;
  return _downloader = Downloader(
    server: _AppServer(app.api),
    findTools: () async => Tools.find(own: await _toolsDir()),
  );
}

/// When the app starts and somebody is signed in: carry on fetching if this computer was
/// left doing so.
Future<void> resumeFetching(AppState app) async {
  if (!canFetchMusicHere) return;
  final prefs = await SharedPreferences.getInstance();
  if (prefs.getBool(_kWanted) != true) return;
  final d = _downloaderFor(app)..maxSlots = prefs.getInt(_kSlots) ?? 3;
  d.slots = d.maxSlots;
  if (await _takeTheLock()) await d.start();
}

Future<void> stopFetching() async {
  await _downloader?.stop();
}

Widget thisComputerPage() => const _ThisComputerPage();

class _ThisComputerPage extends StatefulWidget {
  const _ThisComputerPage();

  @override
  State<_ThisComputerPage> createState() => _ThisComputerPageState();
}

class _ThisComputerPageState extends State<_ThisComputerPage> {
  ({bool allowed, bool asked})? _standing;
  Map<String, dynamic>? _workers;
  int _slots = 3;
  bool _busy = false;

  late final AppState _app = context.read<AppState>();
  late final Downloader _d = _downloaderFor(_app);

  @override
  void initState() {
    super.initState();
    _look();
  }

  Future<void> _look() async {
    final prefs = await SharedPreferences.getInstance();
    _slots = prefs.getInt(_kSlots) ?? 3;
    try {
      final s = await _app.api.ingestStanding();
      if (mounted) setState(() => _standing = s);
    } catch (_) {}
    try {
      final w = await _app.api.ingestWorkers();
      if (mounted) setState(() => _workers = w);
    } catch (_) {
      // Not an admin: the list is not theirs to see.
    }
  }

  Future<void> _turn(bool on) async {
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _busy = true);
    final prefs = await SharedPreferences.getInstance();
    try {
      if (on) {
        var s = await _app.api.askToIngest();
        if (mounted) setState(() => _standing = s);
        if (!s.allowed) {
          messenger.say(snack(const Text(
              'Asked. An admin has to say yes before this computer is given work.')));
          return;
        }
        if (!await _takeTheLock()) {
          messenger.say(snack(const Text('Another WetOwl on this computer is already fetching.')));
          return;
        }
        await prefs.setBool(_kWanted, true);
        _d
          ..maxSlots = _slots
          ..slots = _slots;
        await _d.start();
      } else {
        await prefs.setBool(_kWanted, false);
        await _d.stop();
      }
    } catch (e) {
      messenger.say(problem(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final typed = Mag.typewriter(11.5, color: scheme.onSurfaceVariant);
    return PlayerScaffold(
      measure: 760,
      appBar: AppBar(title: const Text('This computer')),
      body: ListenableBuilder(
        listenable: _d,
        builder: (context, _) {
          final s = _standing;
          final line = switch (_d.state) {
            DownloaderState.off => s == null
                ? 'Looking…'
                : s.allowed
                    ? 'Off. Switched on, this computer fetches songs for everybody here.'
                    : s.asked
                        ? 'Asked — waiting for an admin to say yes.'
                        : 'Off.',
            DownloaderState.starting => 'Starting…',
            DownloaderState.idle => 'On, and waiting for something to fetch.',
            DownloaderState.working => 'Fetching ${_d.inFlight.length} '
                '${_d.inFlight.length == 1 ? 'song' : 'songs'}.',
            DownloaderState.coolingDown => 'YouTube pushed back. Resting until '
                '${TimeOfDay.fromDateTime(_d.coolingUntil!).format(context)}, then '
                '${_d.slots} at a time.',
            DownloaderState.noTools => _d.problem ?? 'Some programs are missing.',
            DownloaderState.refused => _d.problem ?? 'The server said no.',
          };
          return ListView(
            padding: EdgeInsets.fromLTRB(16, 8, 16, bottomForPlayer(context)),
            children: [
              const Kicker('The house downloader'),
              const SizedBox(height: 2),
              Text('FETCH MUSIC HERE', style: Mag.headline(34, color: scheme.onSurface)),
              const SizedBox(height: 6),
              Text(
                  'YouTube answers a home connection and refuses a server in a datacentre, '
                  'so the songs everybody adds are fetched by a computer in somebody’s '
                  'house. This can be one of them: while WetOwl is open it fetches what is '
                  'asked for, hands it to the server, and keeps nothing.',
                  style: typed),
              const SizedBox(height: 14),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Fetch music on this computer'),
                subtitle: Text(line),
                value: _d.running,
                onChanged: _busy ? null : _turn,
              ),
              if (_d.state == DownloaderState.noTools) ...[
                const SizedBox(height: 4),
                SelectableText(Tools.howToInstall(_d.tools?.missing ?? const []),
                    style: Mag.typewriter(12, color: scheme.onSurface, bold: true)),
              ],
              ListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('At a time'),
                subtitle: const Text('Fewer is kinder to the connection. It drops by itself '
                    'when YouTube pushes back, and comes back after a steady run.'),
                trailing: DropdownButton<int>(
                  value: _slots,
                  items: [for (var n = 1; n <= 6; n++) DropdownMenuItem(value: n, child: Text('$n'))],
                  onChanged: (n) async {
                    if (n == null) return;
                    setState(() => _slots = n);
                    (await SharedPreferences.getInstance()).setInt(_kSlots, n);
                    _d
                      ..maxSlots = n
                      ..slots = n;
                  },
                ),
              ),
              if (_d.done + _d.failed > 0)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 6),
                  child: Text(
                      [
                        if (_d.done > 0) '${_d.done} fetched since it was switched on',
                        if (_d.failed > 0) '${_d.failed} could not be',
                      ].join(' · '),
                      style: typed),
                ),
              if (_d.inFlight.isNotEmpty) ...[
                const SizedBox(height: 14),
                const SectionFlag('Now'),
                for (final f in _d.inFlight.values)
                  ListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    title: Text(f.job.videoId, style: Mag.typewriter(12, color: scheme.onSurface)),
                    subtitle: LinearProgressIndicator(
                        value: f.stage == 'downloading' ? f.percent : null),
                    trailing: Text(
                        f.stage == 'downloading' ? (f.speed ?? '') : f.stage,
                        style: typed),
                  ),
              ],
              if (_workers != null) _Workers(workers: _workers!, onChanged: _look),
              if (_d.log.isNotEmpty) ...[
                const SizedBox(height: 18),
                const SectionFlag('What it has been doing'),
                const SizedBox(height: 6),
                SelectableText(_d.log.reversed.take(40).join('\n'),
                    style: Mag.typewriter(10.5, color: scheme.onSurfaceVariant)),
              ],
            ],
          );
        },
      ),
    );
  }
}

/// For an admin: every computer that fetches, and every one asking to.
class _Workers extends StatelessWidget {
  const _Workers({required this.workers, required this.onChanged});
  final Map<String, dynamic> workers;
  final VoidCallback onChanged;

  @override
  Widget build(BuildContext context) {
    final api = context.read<AppState>().api;
    final scheme = Theme.of(context).colorScheme;
    final devices = (workers['devices'] ?? const []) as List;
    final house = (workers['house'] ?? const []) as List;
    if (devices.isEmpty && house.isEmpty) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SizedBox(height: 18),
        const SectionFlag('Computers that fetch'),
        for (final w in house)
          ListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            leading: Icon(Icons.dns_outlined, color: scheme.onSurfaceVariant),
            title: Text('${w['name']}'),
            subtitle: Text(w['live'] == true
                ? (w['busy'] as int? ?? 0) > 0
                    ? 'The house’s own · fetching ${w['busy']}'
                    : 'The house’s own · waiting for work'
                : 'The house’s own · not running'),
          ),
        for (final d in devices)
          SwitchListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            secondary: Icon(Icons.desktop_windows_outlined, color: scheme.onSurfaceVariant),
            title: Text('${d['name']} · ${d['owner']}'),
            subtitle: Text(d['allowed'] != true
                ? 'Asking to help'
                : d['live'] == true
                    ? (d['busy'] as int? ?? 0) > 0
                        ? 'Fetching ${d['busy']}'
                        : 'Waiting for work'
                    : 'Allowed · not running'),
            value: d['allowed'] == true,
            onChanged: (on) async {
              final messenger = ScaffoldMessenger.of(context);
              try {
                await api.allowIngest(d['device_id'] as int, on);
              } catch (e) {
                messenger.say(problem(e));
              }
              onChanged();
            },
          ),
      ],
    );
  }
}
