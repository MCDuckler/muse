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
import '../state/booth/parts.dart';
import '../state/updates.dart';
import '../ui/mag.dart';
import '../ui/mag_parts.dart';
import 'background.dart';
import 'downloader.dart';
import 'helper_files.dart';
import 'ingest_http.dart';
import 'render_parts_io.dart' show splitPool;
import 'separation_kit.dart' show separatorSays;
import 'splitter.dart';
import 'status.dart';
import 'tools.dart';

/// Only on a desk. A phone could run the loop but not the programs, and should not be
/// spending its battery and its data on somebody else's playlist.
bool get canFetchMusicHere =>
    defaultTargetPlatform == TargetPlatform.linux ||
    defaultTargetPlatform == TargetPlatform.windows ||
    defaultTargetPlatform == TargetPlatform.macOS;

const _kFetch = 'muse.pool.fetch';
const _kSplit = 'muse.pool.split';
const _kSlots = 'muse.fetchHere.slots';

/// Worked by the windowless program beside the app rather than by the app, so that it
/// goes on when the app is shut.
const _kBackground = 'muse.fetchHere.background';

/// This computer in the pool — every desktop is, unless its owner switches the work
/// off or an admin blocks it (server/muse/pool.py).
///
/// Two kinds of work and two sorts of asker. For the pool: fetch the songs anybody in
/// the house adds, and take records apart for anybody's booth — here in the app while
/// it is open, or by the windowless helper (bin/wetowl_fetch.dart) when the person has
/// asked for that. For the person at this computer, always, whatever the switches say:
/// the song they asked for is fetched here, now, and played from this disk the moment
/// it arrives, before the house even has it; and a record they want in parts is taken
/// apart here when this is the best computer about (PartsStore).
class PoolHere extends ChangeNotifier {
  PoolHere._(this.app, this.folder)
      : files = HelperFiles(folder),
        fetchedDir = Directory('${folder.path}${Platform.pathSeparator}fetched');

  static PoolHere? _instance;

  /// The one for this app, once somebody is signed in on a desk.
  static PoolHere? get instance => _instance;

  static Future<PoolHere?> forApp(AppState app) async {
    if (!canFetchMusicHere) return null;
    final have = _instance;
    if (have != null && identical(have.app, app)) return have;
    final folder = await getApplicationSupportDirectory();
    final p = _instance = PoolHere._(app, folder);
    await p._init();
    return p;
  }

  final AppState app;
  final Directory folder;
  final HelperFiles files;
  final Directory fetchedDir;

  late final Downloader downloader;
  late final Splitter splitter;
  late final BackgroundFetcher background;

  bool fetchForPool = true;
  bool splitForPool = true;
  bool inBackground = false;
  bool hasHelper = false;
  bool atLogin = false;
  int slots = 3;

  /// Whether the separator can run here at all, known after the first look.
  bool canSplit = false;

  /// The pool's work in this app, rather than the helper's: whoever holds the lock.
  bool _holding = false;
  RandomAccessFile? _lock;

  /// Whether this app is the one on this computer doing the pool's work.
  bool get holdsThePool => _holding;

  /// What the helper last said, when it is the one working.
  FetchStatus? heard;
  Timer? _hearing;

  /// Songs fetched here for the person at this computer, by track.
  final fetched = <int, String>{};

  /// Told when one of those arrives: the player starts it.
  void Function(int trackId)? onFetchedHere;

  ApiClient get api => app.api;

  Map<String, dynamic> said() => {
        'fetch': fetchForPool,
        'split': splitForPool && canSplit,
        'gpu': splitter.gpu,
        'cores': Platform.numberOfProcessors,
        'platform': Platform.operatingSystem,
        'background': inBackground,
        'slots': slots,
      };

  Future<void> _init() async {
    separatorSays = debugPrint;
    final prefs = await SharedPreferences.getInstance();
    fetchForPool = prefs.getBool(_kFetch) ?? true;
    splitForPool = prefs.getBool(_kSplit) ?? true;
    slots = prefs.getInt(_kSlots) ?? 3;
    background = BackgroundFetcher(files: files);
    hasHelper = await background.available;
    inBackground = hasHelper && prefs.getBool(_kBackground) == true;
    atLogin = await background.startsAtLogin;

    downloader = Downloader(
      server: HttpIngestServer(
          baseUrl: () => api.baseUrl, token: () => api.token, pool: said, client: net),
      findTools: () async => Tools.find(own: files.tools),
      maxSlots: slots,
      keepDir: fetchedDir,
      onArrived: (id, path) {
        fetched[id] = path;
        onFetchedHere?.call(id);
        notifyListeners();
      },
    )..addListener(notifyListeners);
    splitter = Splitter(
      server: HttpSplitServer(baseUrl: () => api.baseUrl, token: () => api.token, client: net),
      appFolder: folder,
      findFfmpeg: () async => (await Tools.find(own: files.tools)).ffmpeg,
      pool: said,
    )..addListener(notifyListeners);
    // An update swaps the files the helper runs from: it is stopped first, and the new
    // app starts the new helper.
    Updates.stopHelperForUpdate = () async {
      if (await background.alive) await _helperGone();
    };
    // The app's own splits are the pool's too: claimed before, handed in after.
    splitPool = HttpSplitServer(baseUrl: () => api.baseUrl, token: () => api.token, client: net);
    canSplit = await splitter.able();
    await _keepFewFetched();
    _hearing = Timer.periodic(const Duration(seconds: 2), (_) => _hear());
  }

  /// What was fetched here in earlier runs, still on the disk: played from here while
  /// it is, and the oldest let go of past a few dozen — the house has them all.
  Future<void> _keepFewFetched() async {
    try {
      if (!await fetchedDir.exists()) return;
      final all = [
        await for (final f in fetchedDir.list())
          if (f is File && f.path.endsWith('.m4a')) f
      ];
      all.sort((a, b) => b.statSync().modified.compareTo(a.statSync().modified));
      for (final f in all.skip(40)) {
        try {
          await f.delete();
        } catch (_) {}
      }
      for (final f in all.take(40)) {
        final id = int.tryParse(f.uri.pathSegments.last.split('.').first);
        if (id != null) fetched[id] = f.path;
      }
    } catch (_) {}
  }

  /// A song this computer fetched for its person, where it still has it.
  String? fetchedPath(int trackId) => fetched[trackId];

  Future<void> _hear() async {
    if (!inBackground) return;
    final h = await background.status();
    heard = h;
    notifyListeners();
  }

  /// Whether the helper said something lately: it is running.
  bool get helperAlive => (heard?.fresh() ?? false) && heard?.pid != null;

  /// This app's own build, from the stamp beside it: what the helper has to be too.
  late final String? myBuild = () {
    try {
      return File('${File(Platform.resolvedExecutable).parent.path}'
              '${Platform.pathSeparator}build-stamp.txt')
          .readAsStringSync()
          .trim();
    } catch (_) {
      return null;
    }
  }();

  /// Tell the helper to go, and wait until it has — at most [within].
  Future<void> _helperGone({Duration within = const Duration(seconds: 12)}) async {
    await background.stop();
    final until = DateTime.now().add(within);
    while (DateTime.now().isBefore(until) && await background.alive) {
      await Future<void>.delayed(const Duration(milliseconds: 400));
    }
  }

  /// The downloader's side, whichever program is doing it.
  FetchStatus get fetching {
    if (!inBackground) return FetchStatus.of(downloader, splitter: splitter);
    final h = heard;
    if (h == null || !h.fresh()) return const FetchStatus(state: DownloaderState.off);
    return h;
  }

  /// The splitter's side, whichever program is doing it.
  SplitStatus? get splitting => inBackground ? fetching.split : splitStatusOf(splitter);

  // ------------------------------------------------------------------ starting
  /// When the app starts with somebody signed in: into the pool, the way this computer
  /// was left.
  Future<void> resume() async {
    if (inBackground) {
      await _startHelper();
    } else {
      await _startHere();
    }
    // Parts made here before they could be shared: handed in now, in the background.
    unawaited(splitter.shareWhatIsHere());
  }

  Future<bool> _takeTheLock() async {
    if (_lock != null) return true;
    try {
      await folder.create(recursive: true);
      final f = await files.lock.open(mode: FileMode.append);
      await f.lock(FileLock.exclusive);
      _lock = f;
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<void> _dropTheLock() async {
    final held = _lock;
    _lock = null;
    try {
      await held?.unlock();
      await held?.close();
    } catch (_) {}
  }

  Future<void> _startHere() async {
    if (!fetchForPool && !splitForPool) return;
    if (!_holding) {
      // Another WetOwl on this computer — or the helper, going away — has it.
      for (var i = 0; i < 12 && !await _takeTheLock(); i++) {
        await Future<void>.delayed(const Duration(milliseconds: 500));
      }
      if (_lock == null) return;
      _holding = true;
    }
    downloader
      ..maxSlots = slots
      ..slots = slots;
    if (fetchForPool) await downloader.start();
    if (splitForPool && canSplit) await splitter.start();
    notifyListeners();
  }

  Future<void> _stopHere() async {
    await downloader.stop();
    await splitter.stop();
    _holding = false;
    await _dropTheLock();
    notifyListeners();
  }

  Future<void> _startHelper() async {
    final token = api.token;
    if (!hasHelper || token == null) return;
    await _stopHere();
    if (!fetchForPool && !splitForPool) {
      await background.stop();
      return;
    }
    // A helper from another build — left running across an update, which could not
    // replace a program that was running — is stopped and started again as this one.
    await _hear();
    if (helperAlive && myBuild != null && heard?.build != myBuild) {
      debugPrint('pool: the helper is build ${heard?.build}, this is $myBuild: replacing it');
      await _helperGone();
    }
    await background.start(
        server: api.baseUrl,
        token: token,
        slots: slots,
        fetch: fetchForPool,
        split: splitForPool);
    await background.setStartsAtLogin(true);
    atLogin = true;
    for (var i = 0; i < 6 && !helperAlive; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 500));
      await _hear();
    }
    // Still silent, and the helper that last spoke is still running: one that has
    // stopped saying anything but holds the lock, so that the one just started found
    // it taken and left. It is put down and a new one started.
    if (!helperAlive && await _stuckHelperGone()) {
      await background.start(
          server: api.baseUrl, token: token, slots: slots, fetch: fetchForPool, split: splitForPool);
      for (var i = 0; i < 6 && !helperAlive; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 500));
        await _hear();
      }
    }
    notifyListeners();
  }

  /// The process the helper's last status names, where it is still running and is the
  /// helper: stopped. Whether there was one. Linux only — elsewhere a process cannot be
  /// told for the helper by its number alone, and a wrong one is not to be killed.
  Future<bool> _stuckHelperGone() async {
    final other = heard?.pid;
    if (other == null || !Platform.isLinux || other == pid) return false;
    try {
      final line = await File('/proc/$other/cmdline').readAsString();
      if (!line.contains('wetowl-fetch')) return false;
    } catch (_) {
      return false; // not running
    }
    debugPrint('pool: helper $other has gone quiet but holds on: stopping it');
    Process.killPid(other, ProcessSignal.sigkill);
    await Future<void>.delayed(const Duration(milliseconds: 500));
    return true;
  }

  /// The two switches: fetching for the pool, taking records apart for the pool.
  Future<void> set({bool? fetch, bool? split}) async {
    final prefs = await SharedPreferences.getInstance();
    if (fetch != null) {
      fetchForPool = fetch;
      await prefs.setBool(_kFetch, fetch);
    }
    if (split != null) {
      splitForPool = split;
      await prefs.setBool(_kSplit, split);
    }
    notifyListeners();
    if (inBackground) {
      await _startHelper();
    } else {
      if (!fetchForPool) await downloader.stop();
      if (!splitForPool) await splitter.stop();
      if (!fetchForPool && !splitForPool) {
        await _stopHere();
      } else {
        await _startHere();
      }
    }
  }

  /// Which program does the pool's work. Changing it moves the work over.
  Future<void> setBackground(bool on) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kBackground, on);
    inBackground = on && hasHelper;
    notifyListeners();
    if (inBackground) {
      await _startHelper();
    } else {
      await background.stop();
      await background.setStartsAtLogin(false);
      atLogin = false;
      await _startHere();
    }
  }

  Future<void> setSlots(int n) async {
    slots = n;
    (await SharedPreferences.getInstance()).setInt(_kSlots, n);
    downloader
      ..maxSlots = n
      ..slots = n;
    if (inBackground) await background.setSlots(n);
    notifyListeners();
  }

  /// After installing a missing program: another go, whoever is going.
  Future<void> lookAgain() async {
    if (inBackground) {
      await _startHelper();
    } else {
      await downloader.stop();
      await _startHere();
    }
  }

  Future<Directory> toolsDir() async => files.tools;

  // ------------------------------------------------------------------ the person here
  /// Songs the person at this computer is about to hear that the house does not have
  /// yet: fetched here, now, the first couple of them.
  Future<void> wantHere(List<int> trackIds) async {
    for (final id in trackIds.take(2)) {
      if (fetched.containsKey(id)) continue;
      try {
        await downloader.fetchNow(id);
      } catch (e) {
        debugPrint('could not fetch $id here: $e');
      }
    }
  }

  /// On the way out of an account: the token the helper has was that account's.
  Future<void> signOut() async {
    await _stopHere();
    try {
      if (await files.config.exists()) await background.stop();
    } catch (_) {}
    _hearing?.cancel();
    if (identical(_instance, this)) _instance = null;
  }
}

/// When the app starts and somebody is signed in: into the pool.
Future<void> resumeFetching(AppState app) async {
  final p = await PoolHere.forApp(app);
  if (p == null) return;
  // A computer with a graphics card takes its own records apart at once; any other
  // asks the pool first (PartsStore).
  PartsStore.bestHere = () => p.splitter.gpu;
  final player = app.player;
  if (player != null) {
    player.wantFetchedHere = p.wantHere;
    p.onFetchedHere = (id) => unawaited(player.localArrived(id));
  }
  await p.resume();
}

/// On the way out of an account.
Future<void> stopFetching() async => PoolHere.instance?.signOut();

/// A song this computer fetched for its person, where it still has it.
String? fetchedHerePath(int trackId) => PoolHere.instance?.fetchedPath(trackId);


/// This computer's part in the pool, for the top of the pool page: what it does for
/// everybody, whether it goes on with the app shut, what it is doing now, and — where
/// something it needs is missing — how to get it. Nothing in a browser.
Widget thisComputerCard() => const _ThisComputer();

class _ThisComputer extends StatefulWidget {
  const _ThisComputer();

  @override
  State<_ThisComputer> createState() => _ThisComputerState();
}

class _ThisComputerState extends State<_ThisComputer> {
  PoolHere? _p;
  bool _busy = false;
  bool _showLog = false;

  @override
  void initState() {
    super.initState();
    _find();
  }

  Future<void> _find() async {
    final app = context.read<AppState>();
    PoolHere? p;
    try {
      p = await PoolHere.forApp(app);
    } catch (e) {
      debugPrint('pool: could not look at this computer: $e');
    }
    if (!mounted || p == null) return;
    p.addListener(_changed);
    setState(() => _p = p);
  }

  @override
  void dispose() {
    _p?.removeListener(_changed);
    super.dispose();
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  Future<void> _do(Future<void> Function() f) async {
    setState(() => _busy = true);
    try {
      await f();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = _p;
    final scheme = Theme.of(context).colorScheme;
    final typed = Mag.typewriter(11.5, color: scheme.onSurfaceVariant);
    if (p == null) return const SizedBox.shrink();
    final f = p.fetching;
    final sp = p.splitting;
    final fetchLine = !p.fetchForPool
        ? 'Off: only the songs you ask for are fetched here.'
        : switch (f.state) {
            DownloaderState.off => p.inBackground
                ? p.helperAlive
                    ? 'Starting…'
                    : 'The helper is not running.'
                : p.holdsThePool
                    ? 'Starting…'
                    : 'Another WetOwl on this computer is doing the pool’s work.',
            DownloaderState.starting => 'Starting…',
            DownloaderState.idle => 'Waiting for songs to fetch.',
            DownloaderState.working =>
              'Fetching ${f.inFlight.length} ${f.inFlight.length == 1 ? 'song' : 'songs'}.',
            DownloaderState.coolingDown => 'YouTube pushed back. Resting'
                '${f.coolingUntil == null ? '' : ' until ${TimeOfDay.fromDateTime(f.coolingUntil!).format(context)}'}'
                ', then ${f.slots} at a time.',
            DownloaderState.noTools => 'Some programs it needs are not on this computer.',
            DownloaderState.refused => f.problem ?? 'An admin has kept this computer out.',
          };
    final card = p.splitter.gpu;
    final splitLine = !p.canSplit
        ? 'This copy of WetOwl cannot take records apart.'
        : !p.splitForPool
            ? 'Off: only the records you want in parts are taken apart here, and only '
                'when no better computer is about.'
            : switch (sp?.state) {
                SplitterState.working => 'Taking track ${sp!.trackId} apart · '
                    '${sp.stage ?? ''}${sp.percent == null ? '' : ' ${(sp.percent! * 100).floor()}%'}'
                    '${sp.device == null ? '' : ' · ${sp.device == 'cuda' ? 'graphics card' : 'processor'}'}',
                SplitterState.idle => card
                    ? 'Waiting for records — this one is asked first: it has a graphics card.'
                    : 'Waiting for records nobody with a graphics card has taken within a minute.',
                SplitterState.refused => sp?.problem ?? 'An admin has kept this computer out.',
                SplitterState.noSeparator => 'This copy of WetOwl cannot take records apart.',
                _ => p.inBackground && !p.helperAlive ? 'The helper is not running.' : 'Starting…',
              };
    final log = p.inBackground
        ? [...f.log, ...?sp?.log]
        : [...p.downloader.log, ...p.splitter.log];
    log.sort();
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
      child: Container(
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 8),
        decoration: BoxDecoration(border: Border.all(color: scheme.onSurface, width: 1.5)),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(children: [
              const Kicker('This computer'),
              const Spacer(),
              _Badge(card ? 'GRAPHICS CARD' : '${Platform.numberOfProcessors} CORES',
                  strong: card),
            ]),
            const SizedBox(height: 6),
            Text(
                'Whatever you ask for is fetched and taken apart here first, and shared with '
                'everybody. Switched on, this computer also works for the rest of the house.',
                style: typed),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Fetch songs for everybody'),
              subtitle: Text(fetchLine),
              value: p.fetchForPool,
              onChanged: _busy ? null : (v) => _do(() => p.set(fetch: v)),
            ),
            if (f.state == DownloaderState.noTools && p.fetchForPool)
              _Missing(
                  missing: f.missing,
                  onLookAgain: _busy ? null : () => _do(p.lookAgain),
                  onOpenFolder: () async {
                    final dir = await p.toolsDir();
                    await dir.create(recursive: true);
                    await launchUrl(Uri.file(dir.path));
                  }),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Take records apart for everybody'),
              subtitle: Text(splitLine),
              value: p.splitForPool && p.canSplit,
              onChanged: _busy || !p.canSplit ? null : (v) => _do(() => p.set(split: v)),
            ),
            if (p.splitter.sharing > 0)
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Text(
                    'Sharing records taken apart here before: '
                    '${p.splitter.shared} of ${p.splitter.sharing}',
                    style: typed),
              ),
            if (sp?.state == SplitterState.working && sp?.percent != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: LinearProgressIndicator(value: sp!.percent),
              ),
            if (p.hasHelper)
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Keep working when WetOwl is closed'),
                subtitle: Text(p.inBackground
                    ? 'A small program with no window does the pool’s work'
                        '${p.atLogin ? ', and starts when you log in' : ''}'
                        '${p.helperAlive ? '' : ' — not running right now'}.'
                    : 'The pool’s work stops when the app is shut.'),
                value: p.inBackground,
                onChanged: _busy ? null : (v) => _do(() => p.setBackground(v)),
              ),
            ListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Songs at a time'),
              subtitle: const Text('Fewer is kinder to the connection; it drops by itself '
                  'when YouTube pushes back.'),
              trailing: DropdownButton<int>(
                value: p.slots,
                items: [
                  for (var n = 1; n <= 6; n++) DropdownMenuItem(value: n, child: Text('$n'))
                ],
                onChanged: (n) => n == null ? null : _do(() => p.setSlots(n)),
              ),
            ),
            if (f.inFlight.isNotEmpty)
              for (final x in f.inFlight)
                ListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.download, size: 18),
                  title: Text(x.videoId, style: Mag.typewriter(12, color: scheme.onSurface)),
                  subtitle: LinearProgressIndicator(
                      value: x.stage == 'downloading' ? x.percent : null),
                  trailing: Text(x.stage == 'downloading' ? (x.speed ?? '') : x.stage,
                      style: typed),
                ),
            Wrap(spacing: 12, children: [
              Text('${f.done} fetched · ${sp?.done ?? 0} taken apart since it started'
                  '${f.failed + (sp?.failed ?? 0) > 0 ? ' · ${f.failed + (sp?.failed ?? 0)} failed' : ''}',
                  style: typed),
              if (log.isNotEmpty)
                TextButton(
                  onPressed: () => setState(() => _showLog = !_showLog),
                  child: Text(_showLog ? 'Hide what it did' : 'What it did'),
                ),
            ]),
            if (_showLog)
              SelectableText(log.reversed.take(60).join('\n'),
                  style: Mag.typewriter(10.5, color: scheme.onSurfaceVariant)),
          ],
        ),
      ),
    );
  }
}

class _Badge extends StatelessWidget {
  const _Badge(this.text, {this.strong = false});
  final String text;
  final bool strong;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      color: strong ? scheme.primary : scheme.surfaceContainerHighest,
      child: Text(text,
          style: Mag.flag(9, color: strong ? scheme.onPrimary : scheme.onSurfaceVariant)),
    );
  }
}

/// What is not on this computer, and where each of them comes from: a command for
/// whoever has a package manager, a link and a folder for everybody else.
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
      decoration: BoxDecoration(border: Border.all(color: scheme.outline)),
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

/// Fetch these songs on this computer now, for the person here (the booth's crate
/// adding something the house does not have yet). Nothing where there is no desk.
Future<void> fetchHereNow(List<int> trackIds) async =>
    PoolHere.instance?.wantHere(trackIds);
