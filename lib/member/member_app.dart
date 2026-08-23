import 'dart:async';

import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../config.dart';
import '../models/member_view.dart';
import '../models/track.dart';
import '../services/open_spotify.dart';
import '../services/spotify_web_api.dart';
import 'install_hint.dart';
import 'member_controller.dart';
import 'qr_scanner_screen.dart';

class MemberApp extends StatefulWidget {
  const MemberApp({super.key});

  @override
  State<MemberApp> createState() => _MemberAppState();
}

class _MemberAppState extends State<MemberApp> {
  final _controller = MemberController();

  @override
  void initState() {
    super.initState();
    _controller.init();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

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
      home: ListenableBuilder(
        listenable: _controller,
        builder: (context, _) => switch (_controller.phase) {
          MemberPhase.loading => const Scaffold(
            body: Center(child: CircularProgressIndicator()),
          ),
          MemberPhase.noHost => NoHostScreen(controller: _controller),
          MemberPhase.needName ||
          MemberPhase.joining => JoinScreen(controller: _controller),
          MemberPhase.joined => PartyScreen(controller: _controller),
        },
      ),
    );
  }
}

// ------------------------------------------------------------- no host

class NoHostScreen extends StatefulWidget {
  const NoHostScreen({super.key, required this.controller});
  final MemberController controller;

  @override
  State<NoHostScreen> createState() => _NoHostScreenState();
}

class _NoHostScreenState extends State<NoHostScreen> {
  final _link = TextEditingController();

  @override
  void dispose() {
    _link.dispose();
    super.dispose();
  }

  Future<void> _scan() async {
    final result = await Navigator.push<String>(
      context,
      MaterialPageRoute(builder: (_) => const QrScannerScreen()),
    );
    if (result != null) await widget.controller.setHost(result);
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.controller;
    return Scaffold(
      appBar: AppBar(title: const Text('Spot')),
      body: ListView(
        padding: const EdgeInsets.all(24),
        children: [
          const Text(
            'Join a party by scanning the host\'s QR code with your camera '
            'app — or scan it from here:',
          ),
          const SizedBox(height: 16),
          FilledButton.icon(
            onPressed: _scan,
            icon: const Icon(Icons.qr_code_scanner),
            label: const Text('Scan QR code'),
          ),
          const SizedBox(height: 32),
          TextField(
            controller: _link,
            decoration: const InputDecoration(
              labelText: 'Or paste a join link',
              border: OutlineInputBorder(),
            ),
            onSubmitted: c.setHost,
          ),
          const SizedBox(height: 8),
          OutlinedButton(
            onPressed: () => c.setHost(_link.text),
            child: const Text('Use link'),
          ),
          if (c.error != null) ...[
            const SizedBox(height: 16),
            Text(
              c.error!,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          ],
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------- join

class JoinScreen extends StatefulWidget {
  const JoinScreen({super.key, required this.controller});
  final MemberController controller;

  @override
  State<JoinScreen> createState() => _JoinScreenState();
}

class _JoinScreenState extends State<JoinScreen> {
  late final TextEditingController _name;

  @override
  void initState() {
    super.initState();
    _name = TextEditingController(text: widget.controller.identity.name ?? '');
  }

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.controller;
    final joining = c.phase == MemberPhase.joining;
    return Scaffold(
      appBar: AppBar(
        title: Text("Join ${c.displayHostName}'s party"),
        actions: [
          IconButton(
            tooltip: 'Different party',
            onPressed: c.leave,
            icon: const Icon(Icons.logout),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(24),
        children: [
          TextField(
            controller: _name,
            autofocus: !c.identity.hasName,
            decoration: const InputDecoration(
              labelText: 'Your name',
              border: OutlineInputBorder(),
            ),
            textInputAction: TextInputAction.done,
            onSubmitted: (v) => v.trim().isEmpty ? null : c.join(v),
          ),
          const SizedBox(height: 16),
          FilledButton.icon(
            onPressed: joining
                ? null
                : () {
                    final n = _name.text.trim();
                    if (n.isNotEmpty) c.join(n);
                  },
            icon: joining
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(),
                  )
                : const Icon(Icons.login),
            label: Text(joining ? 'Joining…' : 'Join'),
          ),
          const SizedBox(height: 16),
          Text(
            'Your browser will ask to allow notifications: that is how the '
            'host sends you the queue and the search token.\n'
            'Notification permission right now: ${c.push.permission}'
            '${c.push.error == null ? '' : ' (${c.push.error})'}',
            style: const TextStyle(color: Colors.white60),
          ),
          if (c.error != null) ...[
            const SizedBox(height: 16),
            Text(
              c.error!,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          ],
          const InstallHint(),
        ],
      ),
    );
  }
}

// --------------------------------------------------------------- party

class PartyScreen extends StatefulWidget {
  const PartyScreen({super.key, required this.controller});
  final MemberController controller;

  @override
  State<PartyScreen> createState() => _PartyScreenState();
}

class _PartyScreenState extends State<PartyScreen> {
  final _query = TextEditingController();
  List<Track> _results = const [];
  bool _searching = false;
  String? _searchError;
  Timer? _ticker;
  Timer? _debounce;
  int _searchSeq = 0;
  TrackCollection? _collection;
  final _filter = TextEditingController();
  bool _loadingMore = false;
  bool _loadAll = false;
  final _joinedAt = DateTime.now();

  MemberController get c => widget.controller;

  @override
  void initState() {
    super.initState();
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      final now = c.view?.now;
      final waiting = c.view == null;
      if ((waiting || (now != null && !now.paused)) && mounted) setState(() {});
    });
    final shared = c.takeSharedText();
    if (shared != null) {
      final link = SpotifyLink.parse(shared);
      final short = SpotifyLink.shortUrl(shared);
      if (link != null) {
        _query.text = shared.trim();
        WidgetsBinding.instance.addPostFrameCallback((_) => _openLink(link));
      } else if (short != null) {
        _query.text = short;
        WidgetsBinding.instance.addPostFrameCallback(
          (_) => _resolveShort(short),
        );
      }
    }
  }

  @override
  void dispose() {
    _ticker?.cancel();
    _debounce?.cancel();
    _query.dispose();
    _filter.dispose();
    _loadAll = false;
    super.dispose();
  }

  /// Spotify short share links (open.spotify.com/s/…) can't be followed
  /// from a web page; the host does it for us, then we open the real link.
  Future<void> _resolveShort(String url) async {
    _debounce?.cancel();
    final seq = ++_searchSeq;
    setState(() {
      _searching = true;
      _searchError = null;
      _results = const [];
      _collection = null;
    });
    final full = await c.resolveShortLink(url);
    if (!mounted || seq != _searchSeq) return;
    if (full == null) {
      setState(() {
        _searching = false;
        _searchError =
            'Could not resolve that short link via the host. In '
            'Spotify, open the playlist → ⋯ → Share → Copy link and paste '
            'the full open.spotify.com/playlist/… link.';
      });
      return;
    }
    _query.text = full;
    final link = SpotifyLink.parse(full);
    if (link != null) await _openLink(link);
  }

  /// Search as you type: wait for a pause in typing, ignore stale responses.
  /// A pasted Spotify link opens that track/playlist/album instead.
  void _onQueryChanged(String text) {
    _debounce?.cancel();
    final link = SpotifyLink.parse(text);
    if (link != null) {
      _debounce = Timer(
        const Duration(milliseconds: 200),
        () => _openLink(link),
      );
      return;
    }
    final short = SpotifyLink.shortUrl(text);
    if (short != null) {
      _debounce = Timer(
        const Duration(milliseconds: 200),
        () => _resolveShort(short),
      );
      return;
    }
    final q = text.trim();
    if (q.length < 2) {
      if (_results.isNotEmpty || _searchError != null) {
        setState(() {
          _results = const [];
          _searchError = null;
        });
      }
      return;
    }
    _debounce = Timer(const Duration(milliseconds: 450), _search);
  }

  Future<void> _openLink(SpotifyLink link) async {
    _debounce?.cancel();
    final seq = ++_searchSeq;
    setState(() {
      _searching = true;
      _searchError = null;
      _results = const [];
    });
    try {
      final col = await c.openLink(link);
      if (mounted && seq == _searchSeq) {
        setState(() {
          _collection = col;
          _filter.clear();
        });
      }
    } catch (e) {
      if (mounted && seq == _searchSeq) setState(() => _searchError = '$e');
    } finally {
      if (mounted && seq == _searchSeq) setState(() => _searching = false);
    }
  }

  /// Loads the next page of the open playlist, or everything when [all].
  Future<void> _loadMore({bool all = false}) async {
    final col = _collection;
    if (col == null || col.complete || _loadingMore) return;
    setState(() {
      _loadingMore = true;
      _loadAll = all;
    });
    try {
      do {
        final more = await c.loadMore(col);
        if (!mounted || _collection != col) return;
        setState(() {});
        if (!more) break;
      } while (_loadAll && !col.complete);
    } catch (e) {
      if (mounted) setState(() => _searchError = '$e');
    } finally {
      if (mounted) {
        setState(() {
          _loadingMore = false;
          _loadAll = false;
        });
      }
    }
  }

  Future<void> _search() async {
    _debounce?.cancel();
    final q = _query.text.trim();
    if (q.isEmpty) return;
    final link = SpotifyLink.parse(q);
    if (link != null) return _openLink(link);
    final short = SpotifyLink.shortUrl(q);
    if (short != null) return _resolveShort(short);
    final seq = ++_searchSeq;
    setState(() {
      _searching = true;
      _searchError = null;
    });
    try {
      final r = await c.search(q);
      if (mounted && seq == _searchSeq) {
        setState(() {
          _results = r;
          _collection = null;
        });
      }
    } catch (e) {
      if (mounted && seq == _searchSeq) setState(() => _searchError = '$e');
    } finally {
      if (mounted && seq == _searchSeq) setState(() => _searching = false);
    }
  }

  Future<void> _rename() async {
    final ctrl = TextEditingController(text: c.identity.name ?? '');
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Your name'),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          decoration: const InputDecoration(border: OutlineInputBorder()),
          textInputAction: TextInputAction.done,
          onSubmitted: (v) => Navigator.pop(ctx, v),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, ctrl.text),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    if (name != null && name.trim().isNotEmpty) await c.rename(name);
  }

  Future<void> _skip(NowInfo n) async {
    final remaining =
        n.track.durationMs -
        n.positionAt(DateTime.now().millisecondsSinceEpoch);
    final yes = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Skip "${n.track.name}"?'),
        content: Text(
          n.memberUuid.isEmpty
              ? 'This one isn\'t a party song (Spotify was already playing '
                    'it), so skipping is free — the party takes over right away.'
              : 'The remaining ${formatMs(remaining)} is added to YOUR airtime — '
                    'you pay to veto, ${n.memberName} only pays for what was heard.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Keep playing'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(
              n.memberUuid.isEmpty ? 'Skip' : 'Skip (+${formatMs(remaining)})',
            ),
          ),
        ],
      ),
    );
    if (yes == true) await c.skip(n.track.id);
  }

  Future<void> _addPlaylistEntry(TrackCollection col) async {
    final messenger = ScaffoldMessenger.of(context);
    await c.enqueuePlaylist(col.id!, col.name, col.total);
    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(
            'Added playlist "${col.name}" as one entry '
            '(${col.total} songs)',
          ),
        ),
      );
  }

  Future<void> _add(Track t) async {
    try {
      await c.enqueue(t);
      if (mounted) {
        ScaffoldMessenger.of(context)
          ..hideCurrentSnackBar()
          ..showSnackBar(
            SnackBar(
              content: Text('Added ${t.name}'),
              duration: const Duration(seconds: 2),
            ),
          );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Could not add: $e')));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final v = c.view;
    return Scaffold(
      appBar: AppBar(
        title: Text("${c.displayHostName}'s party"),
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(3),
          child: c.waiting
              ? const LinearProgressIndicator(minHeight: 3)
              : const SizedBox(height: 3),
        ),
        actions: [
          IconButton(
            tooltip: 'Change my name',
            onPressed: _rename,
            icon: const Icon(Icons.edit),
          ),
          IconButton(
            tooltip: 'Refresh',
            onPressed: c.requestState,
            icon: const Icon(Icons.refresh),
          ),
          IconButton(
            tooltip: 'Leave',
            onPressed: c.leave,
            icon: const Icon(Icons.logout),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _NowPlayingCard(
            now: v?.now,
            waiting: v == null,
            onSkip: v?.now == null ? null : () => _skip(v!.now!),
          ),
          if (v?.pausedReason != null)
            Card(
              color: theme.colorScheme.errorContainer,
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Row(
                  children: [
                    Icon(
                      Icons.pause_circle_outline,
                      color: theme.colorScheme.onErrorContainer,
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        v!.pausedReason!,
                        style: TextStyle(
                          color: theme.colorScheme.onErrorContainer,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          if (v?.notice != null &&
              DateTime.now().millisecondsSinceEpoch - v!.noticeAt < 90000)
            Padding(
              padding: const EdgeInsets.only(top: 6, left: 4),
              child: Text(
                v.notice!,
                style: const TextStyle(fontSize: 12, color: Colors.white60),
              ),
            ),
          if (v == null &&
              DateTime.now().difference(_joinedAt) >
                  const Duration(seconds: 10))
            Card(
              color: theme.colorScheme.surfaceContainerHighest,
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      "${c.displayHostName} isn't answering. Is the party "
                      'running on their phone? If you are at a different '
                      'party, scan its QR code.',
                      style: theme.textTheme.bodyMedium,
                    ),
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        OutlinedButton.icon(
                          onPressed: c.requestState,
                          icon: const Icon(Icons.refresh, size: 18),
                          label: const Text('Retry'),
                        ),
                        const SizedBox(width: 8),
                        OutlinedButton.icon(
                          onPressed: c.leave,
                          icon: const Icon(Icons.qr_code_scanner, size: 18),
                          label: const Text('Other party'),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          const SizedBox(height: 16),
          TextField(
            controller: _query,
            decoration: InputDecoration(
              labelText: 'Search Spotify — or paste a Spotify link',
              border: const OutlineInputBorder(),
              suffixIcon: _searching
                  ? const Padding(
                      padding: EdgeInsets.all(12),
                      child: SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                    )
                  : IconButton(
                      icon: const Icon(Icons.search),
                      onPressed: _search,
                    ),
            ),
            textInputAction: TextInputAction.search,
            onChanged: _onQueryChanged,
            onSubmitted: (_) => _search(),
          ),
          if (_searchError != null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                _searchError!,
                style: TextStyle(color: theme.colorScheme.error),
              ),
            ),
          if (_collection != null) ...[
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      '${_collection!.kind}: ${_collection!.name} · '
                      '${_collection!.complete ? '' : 'loaded '}'
                      '${_collection!.tracks.length}'
                      '${_collection!.complete ? '' : ' of ${_collection!.total}'}'
                      ' tracks',
                      style: theme.textTheme.titleSmall,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  IconButton(
                    tooltip: 'Close',
                    icon: const Icon(Icons.close, size: 18),
                    onPressed: () => setState(() {
                      _collection = null;
                      _loadAll = false;
                      _query.clear();
                    }),
                  ),
                ],
              ),
            ),
            if (_collection!.tracks.length > 8 || !_collection!.complete)
              TextField(
                controller: _filter,
                decoration: const InputDecoration(
                  isDense: true,
                  prefixIcon: Icon(Icons.filter_list, size: 18),
                  hintText: 'Filter this list',
                  border: OutlineInputBorder(),
                ),
                onChanged: (_) => setState(() {}),
              ),
            for (final t in _collection!.tracks.where(_matchesFilter))
              ListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                leading: _art(t),
                title: Text(t.name, overflow: TextOverflow.ellipsis),
                subtitle: Text(
                  '${t.artists} · ${formatMs(t.durationMs)}',
                  overflow: TextOverflow.ellipsis,
                ),
                trailing: IconButton(
                  tooltip: 'Add to my queue',
                  icon: const Icon(Icons.add_circle_outline),
                  onPressed: () => _add(t),
                ),
                onTap: () => openInSpotify(t),
              ),
            if (_collection!.kind == 'Playlist' && _collection!.id != null)
              Padding(
                padding: const EdgeInsets.only(top: 4, bottom: 4),
                child: FilledButton.tonalIcon(
                  onPressed: () => _addPlaylistEntry(_collection!),
                  icon: const Icon(Icons.playlist_add, size: 18),
                  label: Text(
                    'Add playlist as entry (${_collection!.total} songs)',
                  ),
                ),
              ),
            if (!_collection!.complete)
              Row(
                children: [
                  OutlinedButton.icon(
                    onPressed: _loadingMore ? null : () => _loadMore(),
                    icon: _loadingMore && !_loadAll
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.expand_more, size: 18),
                    label: const Text('Load more'),
                  ),
                  const SizedBox(width: 8),
                  OutlinedButton.icon(
                    onPressed: _loadingMore ? null : () => _loadMore(all: true),
                    icon: _loadAll
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.unfold_more, size: 18),
                    label: Text(
                      _loadAll
                          ? '${_collection!.tracks.length} / ${_collection!.total}'
                          : 'Load all',
                    ),
                  ),
                ],
              ),
          ],
          for (final t in _results)
            ListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              leading: _art(t),
              title: Text(t.name, overflow: TextOverflow.ellipsis),
              subtitle: Text(
                '${t.artists} · ${formatMs(t.durationMs)}',
                overflow: TextOverflow.ellipsis,
              ),
              trailing: IconButton(
                tooltip: 'Add to my queue',
                icon: const Icon(Icons.add_circle_outline),
                onPressed: () => _add(t),
              ),
              onTap: () => openInSpotify(t),
            ),
          if (_results.isNotEmpty)
            TextButton(
              onPressed: () => setState(() => _results = const []),
              child: const Text('Clear results'),
            ),
          const SizedBox(height: 16),
          Row(
            children: [
              Expanded(
                child: Text(
                  'My queue (${c.identity.name ?? 'me'})'
                  '${v == null ? '' : ' · airtime ${formatMs(_myAirtime(v))}'}',
                  style: theme.textTheme.titleMedium,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              IconButton(
                tooltip: 'Change my name',
                visualDensity: VisualDensity.compact,
                onPressed: _rename,
                icon: const Icon(Icons.edit, size: 18),
              ),
              _ModeButton(
                tooltip: v?.shuffle == true
                    ? 'Shuffle on: every song (also inside playlists) is '
                          'equally likely'
                    : 'Shuffle off: play in order',
                icon: Icons.shuffle,
                selected: v?.shuffle == true,
                onPressed: v == null
                    ? null
                    : () => c.setModes(shuffle: !v.shuffle),
              ),
              _ModeButton(
                tooltip: v?.repeat == true
                    ? 'Repeat on: entries stay and wrap around'
                    : 'Repeat off: entries are removed when played',
                icon: Icons.repeat,
                selected: v?.repeat == true,
                onPressed: v == null
                    ? null
                    : () => c.setModes(repeat: !v.repeat),
              ),
            ],
          ),
          if (v == null || v.myQueue.isEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 8),
              child: Text(
                'Nothing queued — search above.',
                style: TextStyle(color: Colors.white60),
              ),
            ),
          if (v != null && v.myQueue.isNotEmpty)
            AnimatedOpacity(
              opacity: c.waiting ? 0.55 : 1,
              duration: const Duration(milliseconds: 200),
              child: ReorderableListView(
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                buildDefaultDragHandles: false,
                onReorderItem: (oldIndex, newIndex) {
                  final ids = v.myQueue.map((q) => q.id).toList();
                  ids.insert(newIndex, ids.removeAt(oldIndex));
                  c.reorder(ids);
                },
                children: [
                  for (var i = 0; i < v.myQueue.length; i++)
                    ListTile(
                      key: ValueKey(v.myQueue[i].id),
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      selected: v.repeat && !v.shuffle && i == v.cursor,
                      leading: ReorderableDragStartListener(
                        index: i,
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Icon(
                              Icons.drag_handle,
                              color: Colors.white54,
                            ),
                            const SizedBox(width: 6),
                            v.myQueue[i].playlist != null
                                ? const Icon(Icons.queue_music)
                                : _art(v.myQueue[i].track!),
                          ],
                        ),
                      ),
                      title: Text(
                        v.myQueue[i].title,
                        overflow: TextOverflow.ellipsis,
                      ),
                      subtitle: Text(
                        v.myQueue[i].playlist != null
                            ? 'Playlist · '
                                  '${v.shuffle ? v.myQueue[i].playlist!.playedIds.length : v.myQueue[i].playlist!.nextIndex}'
                                  ' / ${v.myQueue[i].playlist!.total} played'
                                  '${v.repeat ? '' : ' · removed when done'}'
                            : '${v.myQueue[i].track!.artists} · '
                                  '${formatMs(v.myQueue[i].track!.durationMs)}',
                        overflow: TextOverflow.ellipsis,
                      ),
                      trailing: IconButton(
                        tooltip: 'Remove',
                        icon: const Icon(Icons.remove_circle_outline),
                        onPressed: () => c.dequeue(v.myQueue[i].id),
                      ),
                      onTap: v.myQueue[i].track == null
                          ? () => launchUrl(
                              Uri.parse(
                                'https://open.spotify.com/playlist/${v.myQueue[i].playlist!.id}',
                              ),
                              mode: LaunchMode.externalApplication,
                            )
                          : () => openInSpotify(v.myQueue[i].track!),
                    ),
                ],
              ),
            ),
          const SizedBox(height: 16),
          Text('Everyone else', style: theme.textTheme.titleMedium),
          if (v == null || v.others.isEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 8),
              child: Text(
                'Just you so far.',
                style: TextStyle(color: Colors.white60),
              ),
            ),
          if (v != null)
            for (final o in v.others)
              ListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                leading: Icon(
                  v.now?.memberUuid == o.uuid ? Icons.volume_up : Icons.person,
                  color: v.now?.memberUuid == o.uuid ? Colors.green : null,
                ),
                title: Text(o.name),
                subtitle: Text(
                  'airtime ${formatMs(o.playedMs)} · ${o.queueLength} queued'
                  '${o.nextTrack == null ? '' : ' · next: ${o.nextTrack}'}',
                  overflow: TextOverflow.ellipsis,
                ),
              ),
          const SizedBox(height: 24),
          Text(
            'Fair play: whenever a song ends, the next one comes from whoever '
            'has had the least airtime. Sitting out doesn\'t bank time: an '
            'empty queue keeps pace with the leader. Anyone may skip a song — '
            'the remaining time goes on the skipper\'s airtime.\n\n'
            'Your own playlists: in the Spotify app, Share → Copy link on a '
            'playlist, album or song and paste it here — add songs from it, or '
            'the whole playlist as one entry that plays all its songs (one per '
            'turn) and follows your edits in Spotify. Shuffle gives every song, '
            'loose or in a playlist, the same chance; repeat keeps entries and '
            'wraps around. Installed to the Home Screen, Spot also shows up in '
            'Spotify\'s Share menu. Tap any song to open it in Spotify.',
            style: theme.textTheme.bodySmall?.copyWith(color: Colors.white38),
          ),
          const InstallHint(),
          Padding(
            padding: const EdgeInsets.only(top: 12),
            child: Text(
              'Spot build ${Config.buildStamp}',
              style: theme.textTheme.bodySmall?.copyWith(color: Colors.white24),
            ),
          ),
        ],
      ),
    );
  }

  bool _matchesFilter(Track t) {
    final f = _filter.text.trim().toLowerCase();
    if (f.isEmpty) return true;
    return t.name.toLowerCase().contains(f) ||
        t.artists.toLowerCase().contains(f);
  }

  /// Airtime including the not-yet-credited part of a track of mine that is
  /// playing right now.
  int _myAirtime(MemberView v) {
    final n = v.now;
    if (n == null || n.memberUuid != c.identity.uuid) return v.myPlayedMs;
    final live =
        n.positionAt(DateTime.now().millisecondsSinceEpoch) - n.positionMs;
    return v.myPlayedMs + (live > 0 ? live : 0);
  }

  Widget _art(Track t) => t.imageUrl == null
      ? const Icon(Icons.music_note)
      : Image.network(
          t.imageUrl!,
          width: 40,
          height: 40,
          errorBuilder: (_, _, _) => const Icon(Icons.music_note),
        );
}

class _NowPlayingCard extends StatelessWidget {
  const _NowPlayingCard({
    required this.now,
    required this.waiting,
    this.onSkip,
  });
  final NowInfo? now;
  final bool waiting;
  final VoidCallback? onSkip;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final n = now;
    return Card(
      child: InkWell(
        onTap: n == null ? null : () => openInSpotify(n.track),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: n == null
              ? Text(
                  waiting
                      ? 'Connecting to the host…'
                      : 'Nothing playing — add a song!',
                  style: theme.textTheme.titleMedium,
                )
              : Builder(
                  builder: (context) {
                    final pos = n.positionAt(
                      DateTime.now().millisecondsSinceEpoch,
                    );
                    return Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            if (n.track.imageUrl != null)
                              Padding(
                                padding: const EdgeInsets.only(right: 12),
                                child: Image.network(
                                  n.track.imageUrl!,
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
                                    n.track.name,
                                    style: theme.textTheme.titleMedium,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                  Text(
                                    n.track.artists,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                  Text(
                                    'for ${n.memberName}',
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
                          value: n.track.durationMs > 0
                              ? (pos / n.track.durationMs).clamp(0.0, 1.0)
                              : null,
                        ),
                        const SizedBox(height: 4),
                        Row(
                          children: [
                            Expanded(
                              child: Text(
                                '${formatMs(pos)} / ${formatMs(n.track.durationMs)}'
                                '${n.paused ? '  (paused)' : ''}',
                                style: const TextStyle(fontSize: 12),
                              ),
                            ),
                            if (onSkip != null)
                              TextButton.icon(
                                onPressed: onSkip,
                                icon: const Icon(Icons.skip_next, size: 18),
                                label: Text(
                                  'Skip (+${formatMs(n.track.durationMs - pos)})',
                                ),
                              ),
                          ],
                        ),
                      ],
                    );
                  },
                ),
        ),
      ),
    );
  }
}

/// Small toggle button whose "on" state is a tinted pill, not an inverted
/// glyph (the Material `*_on` icons turn into solid blocks at small sizes).
class _ModeButton extends StatelessWidget {
  const _ModeButton({
    required this.tooltip,
    required this.icon,
    required this.selected,
    required this.onPressed,
  });
  final String tooltip;
  final IconData icon;
  final bool selected;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return IconButton(
      tooltip: tooltip,
      visualDensity: VisualDensity.compact,
      onPressed: onPressed,
      style: IconButton.styleFrom(
        backgroundColor: selected ? scheme.primary : Colors.transparent,
        foregroundColor: selected ? scheme.onPrimary : scheme.onSurfaceVariant,
      ),
      icon: Icon(icon, size: 20),
    );
  }
}
