import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:url_launcher/url_launcher.dart';

import '../config.dart';

import '../models/party.dart';
import '../models/track.dart';
import '../services/identity.dart';
import '../services/open_spotify.dart';
import 'host_controller.dart';
import 'host_player.dart';
import 'host_settings.dart';
import 'spotify_auth.dart';

class HostApp extends StatelessWidget {
  const HostApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Spot',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF1DB954),
          brightness: Brightness.dark,
        ),
        useMaterial3: true,
      ),
      home: const _HostRoot(),
    );
  }
}

class _HostRoot extends StatefulWidget {
  const _HostRoot();

  @override
  State<_HostRoot> createState() => _HostRootState();
}

class _HostRootState extends State<_HostRoot> {
  final _identity = Identity();
  final _auth = SpotifyAuth();
  HostController? _controller;

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    await _identity.init();
    await _auth.load();
    await HostSettings.load();
    final c = HostController(
      identity: _identity,
      auth: _auth,
      player: AppRemotePlayer(),
    );
    await c.loadSavedParty();
    if (mounted) setState(() => _controller = c);
  }

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = _controller;
    if (c == null) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    return ListenableBuilder(
      listenable: c,
      builder: (context, _) => c.phase == HostPhase.running
          ? HostPartyScreen(controller: c)
          : HostSetupScreen(controller: c),
    );
  }
}

// ---------------------------------------------------------------- setup

class HostSetupScreen extends StatefulWidget {
  const HostSetupScreen({super.key, required this.controller});
  final HostController controller;

  @override
  State<HostSetupScreen> createState() => _HostSetupScreenState();
}

class _HostSetupScreenState extends State<HostSetupScreen> {
  late final TextEditingController _name;
  late final TextEditingController _clientId;
  String? _loginError;
  bool _loggingIn = false;

  HostController get c => widget.controller;

  @override
  void initState() {
    super.initState();
    _name = TextEditingController(text: c.identity.name ?? '');
    _clientId = TextEditingController(text: HostSettings.clientId);
  }

  @override
  void dispose() {
    _name.dispose();
    _clientId.dispose();
    super.dispose();
  }

  Future<void> _login() async {
    setState(() {
      _loggingIn = true;
      _loginError = null;
    });
    try {
      await HostSettings.setClientId(_clientId.text);
      await c.auth.login();
    } catch (e) {
      _loginError = '$e';
    }
    if (mounted) setState(() => _loggingIn = false);
  }

  Future<void> _start() async {
    final name = _name.text.trim();
    if (name.isEmpty) return;
    await c.identity.setName(name);
    await HostSettings.setClientId(_clientId.text);
    await c.start();
  }

  @override
  Widget build(BuildContext context) {
    final auth = c.auth;
    final starting = c.phase == HostPhase.starting;
    final hasClientId = _clientId.text.trim().isNotEmpty;
    return Scaffold(
      appBar: AppBar(title: const Text('Spot — host a party')),
      body: ListenableBuilder(
        listenable: auth,
        builder: (context, _) => ListView(
          padding: const EdgeInsets.all(16),
          children: [
            TextField(
              controller: _clientId,
              decoration: const InputDecoration(
                labelText: 'Spotify client id (from the developer dashboard)',
                border: OutlineInputBorder(),
              ),
              autocorrect: false,
              onChanged: (_) => setState(() {}),
              onSubmitted: HostSettings.setClientId,
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _name,
              decoration: const InputDecoration(
                labelText: 'Your name (shown to members)',
                border: OutlineInputBorder(),
              ),
              textInputAction: TextInputAction.done,
            ),
            const SizedBox(height: 16),
            ListTile(
              leading: Icon(
                auth.needsRelogin
                    ? Icons.warning_amber
                    : auth.isLoggedIn
                    ? Icons.check_circle
                    : Icons.music_note,
                color: auth.needsRelogin
                    ? Colors.orange
                    : auth.isLoggedIn
                    ? Colors.green
                    : null,
              ),
              title: Text(
                auth.needsRelogin
                    ? 'Log in again (new permissions needed)'
                    : auth.isLoggedIn
                    ? 'Logged in to Spotify'
                    : 'Log in to Spotify (Premium)',
              ),
              subtitle: _loginError != null
                  ? Text(
                      _loginError!,
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                      ),
                    )
                  : const Text(
                      'The Spotify app on this phone does the playing; '
                      'members search with your token.',
                    ),
              trailing: _loggingIn
                  ? const SizedBox(
                      width: 24,
                      height: 24,
                      child: CircularProgressIndicator(),
                    )
                  : TextButton(
                      onPressed: !hasClientId
                          ? null
                          : auth.isLoggedIn
                          ? auth.logout
                          : _login,
                      child: Text(auth.isLoggedIn ? 'Log out' : 'Log in'),
                    ),
            ),
            const SizedBox(height: 24),
            FilledButton.icon(
              onPressed:
                  hasClientId &&
                      auth.isLoggedIn &&
                      !auth.needsRelogin &&
                      !starting
                  ? _start
                  : null,
              icon: starting
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(),
                    )
                  : const Icon(Icons.play_arrow),
              label: Text(starting ? c.status : 'Start party'),
            ),
            if (c.lastError != null) ...[
              const SizedBox(height: 16),
              Text(
                c.lastError!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ],
            const SizedBox(height: 32),
            if (!c.party.isEmpty)
              OutlinedButton.icon(
                onPressed: c.resetParty,
                icon: const Icon(Icons.delete_outline),
                label: Text(
                  'Forget saved party (${c.party.members.length} queued, '
                  '${c.party.listeners.length} known)',
                ),
              ),
            const SizedBox(height: 24),
            const Text(
              'Checklist: Spotify app installed and logged in with Premium · '
              'this phone is the one connected to the speakers · keep it on '
              'power for long parties.',
              style: TextStyle(color: Colors.white60),
            ),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------- party

class HostPartyScreen extends StatefulWidget {
  const HostPartyScreen({super.key, required this.controller});
  final HostController controller;

  @override
  State<HostPartyScreen> createState() => _HostPartyScreenState();
}

class _HostPartyScreenState extends State<HostPartyScreen> {
  Timer? _ticker;

  HostController get c => widget.controller;

  @override
  void initState() {
    super.initState();
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (c.current != null && !c.paused && mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }

  /// Opens the member page in the browser so the host can join too.
  Future<void> _openJoinLink() async {
    final ok = await launchUrl(
      Uri.parse(c.joinUrl),
      mode: LaunchMode.externalApplication,
    );
    if (!ok && mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Could not open a browser')));
    }
  }

  Future<void> _confirmStop() async {
    final yes = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('End the party?'),
        content: const Text(
          'Playback stops and members lose contact. Queues and airtime are '
          'kept for next time.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Keep going'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('End party'),
          ),
        ],
      ),
    );
    if (yes == true) await c.stop();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final now = c.current;
    final members = c.party.members.toList();
    return Scaffold(
      appBar: AppBar(
        title: Text('Spot — ${c.identity.name ?? 'host'}'),
        actions: [
          IconButton(
            tooltip: 'End party',
            onPressed: _confirmStop,
            icon: const Icon(Icons.stop_circle_outlined),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                children: [
                  const Text(
                    'Scan to join',
                    style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 12),
                  InkWell(
                    onTap: _openJoinLink,
                    child: Container(
                      color: Colors.white,
                      padding: const EdgeInsets.all(8),
                      child: QrImageView(data: c.joinUrl, size: 240),
                    ),
                  ),
                  const SizedBox(height: 4),
                  const Text(
                    'Tap the code or link to join from this phone too',
                    style: TextStyle(fontSize: 11, color: Colors.white60),
                  ),
                  const SizedBox(height: 4),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Flexible(
                        child: InkWell(
                          onTap: _openJoinLink,
                          child: Text(
                            c.joinUrl,
                            style: const TextStyle(
                              fontSize: 11,
                              color: Colors.lightGreenAccent,
                              decoration: TextDecoration.underline,
                            ),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ),
                      IconButton(
                        tooltip: 'Copy link',
                        icon: const Icon(Icons.copy, size: 18),
                        onPressed: () {
                          Clipboard.setData(ClipboardData(text: c.joinUrl));
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(content: Text('Link copied')),
                          );
                        },
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),
          Card(
            child: InkWell(
              onTap: now == null ? null : () => openInSpotify(now.track),
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: now == null
                    ? Text(c.status, style: theme.textTheme.titleMedium)
                    : Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              if (now.track.imageUrl != null)
                                Padding(
                                  padding: const EdgeInsets.only(right: 12),
                                  child: Image.network(
                                    now.track.imageUrl!,
                                    width: 56,
                                    height: 56,
                                    errorBuilder: (_, _, _) =>
                                        const SizedBox(width: 56, height: 56),
                                  ),
                                ),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      now.track.name,
                                      style: theme.textTheme.titleMedium,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                    Text(
                                      now.track.artists,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                    Text(
                                      'for ${c.currentMember?.name ?? '?'}',
                                      style: const TextStyle(
                                        color: Colors.white60,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 8),
                          LinearProgressIndicator(
                            value: c.durationMs > 0
                                ? (c.positionMs / c.durationMs).clamp(0.0, 1.0)
                                : null,
                          ),
                          const SizedBox(height: 4),
                          Text(
                            '${formatMs(c.positionMs)} / ${formatMs(c.durationMs)}'
                            '${c.paused ? '  (paused)' : ''}',
                            style: const TextStyle(fontSize: 12),
                          ),
                          Row(
                            mainAxisAlignment: MainAxisAlignment.end,
                            children: [
                              IconButton(
                                tooltip: c.paused ? 'Resume' : 'Pause',
                                onPressed: c.paused ? c.resume : c.pause,
                                icon: Icon(
                                  c.paused ? Icons.play_arrow : Icons.pause,
                                ),
                              ),
                              IconButton(
                                tooltip: 'Skip',
                                onPressed: c.skip,
                                icon: const Icon(Icons.skip_next),
                              ),
                            ],
                          ),
                        ],
                      ),
              ),
            ),
          ),
          if (c.takenOver)
            Card(
              color: theme.colorScheme.errorContainer,
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      c.takenOverLocally
                          ? 'Someone started other music in the Spotify app on '
                                'this phone — the party is paused until you take '
                                'it back (or it reclaims itself).'
                          : 'Spotify is playing on "${c.takenOverBy}" — the '
                                'party is paused. (One stream per account: '
                                'someone else is using this Spotify account.)',
                      style: TextStyle(
                        color: theme.colorScheme.onErrorContainer,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        FilledButton.icon(
                          onPressed: c.reclaim,
                          icon: const Icon(Icons.phone_android, size: 18),
                          label: const Text('Take back'),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: SwitchListTile(
                            dense: true,
                            contentPadding: EdgeInsets.zero,
                            title: const Text(
                              'Auto-reclaim after 30 s',
                              style: TextStyle(fontSize: 13),
                            ),
                            value: c.autoReclaim,
                            onChanged: c.setAutoReclaim,
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          const SizedBox(height: 8),
          Row(
            children: [
              Icon(
                c.spotifyConnected ? Icons.link : Icons.link_off,
                size: 16,
                color: c.spotifyConnected ? Colors.green : Colors.orange,
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  '${c.spotifyConnected ? 'Spotify connected' : 'Spotify disconnected'}'
                  '${c.ourDeviceName == null ? '' : ' (${c.ourDeviceName})'} · '
                  '${members.length} member${members.length == 1 ? '' : 's'}',
                  style: const TextStyle(fontSize: 12, color: Colors.white60),
                ),
              ),
            ],
          ),
          if (c.lastError != null)
            ListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              leading: Icon(
                Icons.warning_amber,
                color: theme.colorScheme.error,
                size: 18,
              ),
              title: Text(
                c.lastError!,
                style: TextStyle(fontSize: 12, color: theme.colorScheme.error),
              ),
              trailing: IconButton(
                icon: const Icon(Icons.close, size: 16),
                onPressed: c.clearError,
              ),
            ),
          const SizedBox(height: 16),
          Text('Members with songs queued', style: theme.textTheme.titleMedium),
          if (members.isEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 12),
              child: Text(
                'Nobody has queued anything yet.',
                style: TextStyle(color: Colors.white60),
              ),
            ),
          for (final m in members) _MemberTile(member: m, controller: c),
          const SizedBox(height: 12),
          Builder(
            builder: (context) {
              final now = DateTime.now().millisecondsSinceEpoch;
              final live = c.party
                  .recipients(now, Config.listenerTimeout)
                  .toList();
              return Text(
                live.isEmpty
                    ? 'Nobody is looking at the page right now.'
                    : 'Listening now (${live.length}): '
                          '${live.map((l) => l.name).join(', ')}',
                style: const TextStyle(fontSize: 12, color: Colors.white60),
              );
            },
          ),
        ],
      ),
    );
  }
}

class _MemberTile extends StatelessWidget {
  const _MemberTile({required this.member, required this.controller});
  final Member member;
  final HostController controller;

  @override
  Widget build(BuildContext context) {
    final isPlaying = controller.currentMember?.uuid == member.uuid;
    return ExpansionTile(
      leading: Icon(
        isPlaying ? Icons.volume_up : Icons.person,
        color: isPlaying ? Colors.green : null,
      ),
      title: Text(member.name),
      subtitle: Text(
        'airtime ${formatMs(controller.airtimeOf(member))} · ${member.queue.length} queued',
      ),
      children: [
        if (member.queue.isEmpty)
          const ListTile(
            dense: true,
            title: Text(
              'Queue is empty',
              style: TextStyle(color: Colors.white60),
            ),
          ),
        for (final item in member.queue)
          ListTile(
            dense: true,
            leading: item.track.imageUrl == null
                ? const Icon(Icons.music_note)
                : Image.network(
                    item.track.imageUrl!,
                    width: 40,
                    height: 40,
                    errorBuilder: (_, _, _) => const Icon(Icons.music_note),
                  ),
            title: Text(item.track.name, overflow: TextOverflow.ellipsis),
            subtitle: Text(
              '${item.track.artists} · ${formatMs(item.track.durationMs)}',
              overflow: TextOverflow.ellipsis,
            ),
            trailing: IconButton(
              tooltip: 'Remove',
              icon: const Icon(Icons.remove_circle_outline),
              onPressed: () => controller.removeQueued(member.uuid, item.id),
            ),
            onTap: () => openInSpotify(item.track),
          ),
      ],
    );
  }
}
