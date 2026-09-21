import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

import '../api/client.dart';
import '../api/connection.dart';
import '../state/app_state.dart';
import '../ui/mag.dart';
import '../ui/mag_parts.dart';
import '../ui/mini_player.dart';
import '../ui/snack.dart';
import 'background.dart';
import 'downloader.dart';
import 'helper_files.dart';
import 'ingest_http.dart';
import 'status.dart';
import 'tools.dart';

/// Only on a desk. A phone could run the loop but not the programs, and should not be
/// spending its battery and its data on somebody else's playlist.
bool get canFetchMusicHere =>
    defaultTargetPlatform == TargetPlatform.linux ||
    defaultTargetPlatform == TargetPlatform.windows ||
    defaultTargetPlatform == TargetPlatform.macOS;

const _kWanted = 'muse.fetchHere';
const _kSlots = 'muse.fetchHere.slots';

/// Fetched by the windowless program beside the app rather than by the app, so that it
/// goes on when the app is shut.
const _kBackground = 'muse.fetchHere.background';

Downloader? _downloader;
ApiClient? _api;
RandomAccessFile? _lock;

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
  final api = app.api;
  return _downloader = Downloader(
    // The token this device already signs in with, asked for each time: it changes
    // when somebody signs in again.
    server: HttpIngestServer(
        baseUrl: () => api.baseUrl, token: () => api.token, client: net),
    findTools: () async => Tools.find(own: await _toolsDir()),
  );
}

Future<void> _dropTheLock() async {
  final held = _lock;
  _lock = null;
  try {
    await held?.unlock();
    await held?.close();
  } catch (_) {}
}

Future<BackgroundFetcher> _background() async =>
    BackgroundFetcher(files: HelperFiles(await getApplicationSupportDirectory()));

/// When the app starts and somebody is signed in: carry on fetching if this computer was
/// left doing so.
Future<void> resumeFetching(AppState app) async {
  if (!canFetchMusicHere) return;
  final prefs = await SharedPreferences.getInstance();
  if (prefs.getBool(_kWanted) != true) return;
  if (prefs.getBool(_kBackground) == true) {
    // The other program's job. It is very likely running already — that is the point
    // of it — and this only sees that it is, with the token as it is now.
    final bg = await _background();
    final token = app.api.token;
    if (await bg.available && token != null) {
      try {
        await bg.start(
            server: app.api.baseUrl, token: token, slots: prefs.getInt(_kSlots) ?? 3);
      } catch (_) {}
      return;
    }
  }
  final d = _downloaderFor(app)..maxSlots = prefs.getInt(_kSlots) ?? 3;
  d.slots = d.maxSlots;
  if (await _takeTheLock()) await d.start();
}

/// On the way out of an account. The token in the helper's file was that account's;
/// it goes with it, and so does the helper, which cannot fetch without one.
Future<void> stopFetching() async {
  await _downloader?.stop();
  await _dropTheLock();
  try {
    final bg = await _background();
    if (await bg.files.config.exists()) await bg.stop();
  } catch (_) {}
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

  /// The windowless fetcher: whether this copy of the app has one beside it, whether
  /// it is the one doing the fetching, and the last thing it said.
  BackgroundFetcher? _bg;
  bool _hasHelper = false;
  bool _inBackground = false;
  bool _atLogin = false;
  FetchStatus? _heard;
  Timer? _listening;

  /// What is being done, whichever program is doing it.
  FetchStatus get _now {
    if (!_inBackground) return FetchStatus.of(_d);
    final heard = _heard;
    // A file goes on saying "fetching" after the program that wrote it has died.
    if (heard == null || !heard.fresh()) return const FetchStatus(state: DownloaderState.off);
    return heard;
  }

  @override
  void initState() {
    super.initState();
    _d.addListener(_changed);
    _look();
    _listening = Timer.periodic(const Duration(seconds: 2), (_) => _hear());
  }

  @override
  void dispose() {
    _listening?.cancel();
    _d.removeListener(_changed);
    super.dispose();
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  Future<void> _hear() async {
    if (!_inBackground) return;
    final heard = await _bg?.status();
    if (mounted) setState(() => _heard = heard);
  }

  Future<void> _look() async {
    final prefs = await SharedPreferences.getInstance();
    _slots = prefs.getInt(_kSlots) ?? 3;
    final bg = _bg = await _background();
    _hasHelper = await bg.available;
    _inBackground = _hasHelper && prefs.getBool(_kBackground) == true;
    _atLogin = await bg.startsAtLogin;
    await _hear();
    if (mounted) setState(() {});
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
        if (_inBackground) {
          await prefs.setBool(_kWanted, true);
          await _startInBackground();
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
        if (_inBackground) {
          await _bg?.stop();
          // Not left to start by itself tomorrow, having been switched off today.
          await _bg?.setStartsAtLogin(false);
          if (mounted) setState(() => _atLogin = false);
        }
        await _d.stop();
        await _dropTheLock();
      }
    } catch (e) {
      messenger.say(problem(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Hand the work to the other program: the app lets go of it first, because there is
  /// one lock and whoever holds it is the fetcher.
  Future<void> _startInBackground() async {
    final bg = _bg, token = _app.api.token;
    if (bg == null || token == null) return;
    await _d.stop();
    await _dropTheLock();
    await bg.start(server: _app.api.baseUrl, token: token, slots: _slots);
    await bg.setStartsAtLogin(true);
    if (mounted) setState(() => _atLogin = true);
    // It says something as soon as it is up; no need to sit through a whole tick.
    for (var i = 0; i < 6 && mounted && !(_heard?.fresh() ?? false); i++) {
      await Future<void>.delayed(const Duration(milliseconds: 500));
      await _hear();
    }
  }

  /// Which program does the fetching. Changing it while fetching moves the work over
  /// rather than stopping it.
  Future<void> _setBackground(bool on) async {
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _busy = true);
    try {
      final prefs = await SharedPreferences.getInstance();
      final fetching = _now.running || prefs.getBool(_kWanted) == true;
      await prefs.setBool(_kBackground, on);
      setState(() => _inBackground = on);
      if (on) {
        if (fetching) await _startInBackground();
      } else {
        await _bg?.stop();
        await _bg?.setStartsAtLogin(false);
        if (mounted) setState(() => _atLogin = false);
        if (fetching) {
          // It lets go within a few seconds of being told; the lock says when.
          var mine = false;
          for (var i = 0; i < 12 && !mine; i++) {
            await Future<void>.delayed(const Duration(milliseconds: 500));
            mine = await _takeTheLock();
          }
          if (mine) {
            _d
              ..maxSlots = _slots
              ..slots = _slots;
            await _d.start();
          }
        }
      }
    } catch (e) {
      messenger.say(problem(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// After installing what was missing: have another go, whoever is doing the going.
  Future<void> _lookAgain() async {
    setState(() => _busy = true);
    try {
      if (_inBackground) {
        await _startInBackground();
      } else if (await _takeTheLock()) {
        await _d.start();
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _openToolsFolder() async {
    final dir = await _toolsDir();
    await dir.create(recursive: true);
    await launchUrl(Uri.file(dir.path));
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final typed = Mag.typewriter(11.5, color: scheme.onSurfaceVariant);
    return PlayerScaffold(
      measure: 760,
      appBar: AppBar(title: const Text('This computer')),
      body: Builder(
        builder: (context) {
          final s = _standing;
          final now = _now;
          final line = switch (now.state) {
            DownloaderState.off => s == null
                ? 'Looking…'
                : s.allowed
                    ? 'Off. Switched on, this computer fetches songs for everybody here.'
                    : s.asked
                        ? 'Asked — waiting for an admin to say yes.'
                        : 'Off.',
            DownloaderState.starting => 'Starting…',
            DownloaderState.idle => 'On, and waiting for something to fetch.',
            DownloaderState.working => 'Fetching ${now.inFlight.length} '
                '${now.inFlight.length == 1 ? 'song' : 'songs'}.',
            DownloaderState.coolingDown => 'YouTube pushed back. Resting'
                '${now.coolingUntil == null ? '' : ' until ${TimeOfDay.fromDateTime(now.coolingUntil!).format(context)}'}'
                ', then ${now.slots} at a time.',
            DownloaderState.noTools => 'Some programs it needs are not on this computer.',
            DownloaderState.refused => now.problem ?? 'The server said no.',
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
                  'house. This can be one of them: it fetches what is asked for, hands it '
                  'to the server, and keeps nothing.',
                  style: typed),
              const SizedBox(height: 14),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Fetch music on this computer'),
                subtitle: Text(line),
                value: now.running,
                onChanged: _busy ? null : _turn,
              ),
              if (now.state == DownloaderState.noTools)
                _Missing(
                  missing: now.missing,
                  onLookAgain: _busy ? null : _lookAgain,
                  onOpenFolder: _openToolsFolder,
                ),
              if (_hasHelper)
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Keep fetching when WetOwl is closed'),
                  subtitle: Text(_inBackground
                      ? 'A small program with no window does the fetching'
                          '${_atLogin ? ', and starts by itself when you log in' : ''}. '
                          'It stops when this is switched off.'
                      : 'Fetching stops when the app is shut. Switched on, a small program '
                          'with no window does it instead and starts when you log in.'),
                  value: _inBackground,
                  onChanged: _busy ? null : _setBackground,
                ),
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
                    if (_inBackground) await _bg?.setSlots(n);
                  },
                ),
              ),
              if (now.done + now.failed > 0)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 6),
                  child: Text(
                      [
                        if (now.done > 0) '${now.done} fetched since it was switched on',
                        if (now.failed > 0) '${now.failed} could not be',
                      ].join(' · '),
                      style: typed),
                ),
              if (now.inFlight.isNotEmpty) ...[
                const SizedBox(height: 14),
                const SectionFlag('Now'),
                for (final f in now.inFlight)
                  ListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    title: Text(f.videoId, style: Mag.typewriter(12, color: scheme.onSurface)),
                    subtitle: LinearProgressIndicator(
                        value: f.stage == 'downloading' ? f.percent : null),
                    trailing: Text(
                        f.stage == 'downloading' ? (f.speed ?? '') : f.stage,
                        style: typed),
                  ),
              ],
              if (_workers != null) _Workers(workers: _workers!, onChanged: _look),
              if ((_inBackground ? _heard?.log ?? const <String>[] : _d.log).isNotEmpty) ...[
                const SizedBox(height: 18),
                const SectionFlag('What it has been doing'),
                const SizedBox(height: 6),
                SelectableText(
                    (_inBackground ? _heard?.log ?? const <String>[] : _d.log)
                        .reversed
                        .take(40)
                        .join('\n'),
                    style: Mag.typewriter(10.5, color: scheme.onSurfaceVariant)),
              ],
            ],
          );
        },
      ),
    );
  }
}

/// What is not on this computer, and where each of them comes from.
///
/// Two ways in, because there are two kinds of person: a command for whoever has a
/// package manager and knows it, and for everybody else a link to the project's own
/// download and a folder to drop the file in — the app looks there before anywhere.
class _Missing extends StatelessWidget {
  const _Missing({required this.missing, this.onLookAgain, required this.onOpenFolder});

  final List<String> missing;
  final VoidCallback? onLookAgain;
  final VoidCallback onOpenFolder;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final typed = Mag.typewriter(11.5, color: scheme.onSurfaceVariant);
    return Container(
      margin: const EdgeInsets.only(top: 6, bottom: 10),
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 10),
      decoration: BoxDecoration(border: Border.all(color: scheme.onSurface, width: 1.5)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Kicker('Needed first'),
          const SizedBox(height: 8),
          for (final link in Tools.linksFor(missing)) ...[
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(link.name, style: Theme.of(context).textTheme.titleSmall),
                      Text('${link.whatFor}. ${link.note}', style: typed),
                    ],
                  ),
                ),
                const SizedBox(width: 10),
                OutlinedButton.icon(
                  onPressed: () =>
                      launchUrl(Uri.parse(link.url), mode: LaunchMode.externalApplication),
                  icon: const Icon(Icons.open_in_new, size: 16),
                  label: const Text('Get it'),
                ),
              ],
            ),
            const SizedBox(height: 10),
          ],
          Text('Or, with a package manager:', style: typed),
          const SizedBox(height: 2),
          SelectableText(Tools.howToInstall(missing),
              style: Mag.typewriter(12, color: scheme.onSurface, bold: true)),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 4,
            children: [
              TextButton.icon(
                onPressed: onOpenFolder,
                icon: const Icon(Icons.folder_open, size: 18),
                label: const Text('Open the tools folder'),
              ),
              FilledButton.tonalIcon(
                onPressed: onLookAgain,
                icon: const Icon(Icons.refresh, size: 18),
                label: const Text('Look again'),
              ),
            ],
          ),
        ],
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
