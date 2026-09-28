import 'package:flutter/material.dart';

import '../models/history.dart';
import '../models/track.dart';
import '../services/open_spotify.dart';

/// What the party has played, newest first — the same list on the host and on
/// every member's page, so "why did that get cut off" has an answer.
class HistoryList extends StatelessWidget {
  const HistoryList({super.key, required this.history, this.max = 30});

  final List<PlayedSong> history;
  final int max;

  @override
  Widget build(BuildContext context) {
    if (history.isEmpty) return const SizedBox.shrink();
    final theme = Theme.of(context);
    return ExpansionTile(
      tilePadding: EdgeInsets.zero,
      leading: const Icon(Icons.queue_music, size: 20),
      title: const Text('Played so far'),
      subtitle: Text(
        '${history.first.name}${history.first.wasSkipped ? ' (skipped)' : ''}',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(fontSize: 11, color: Colors.white54),
      ),
      children: [
        for (final song in history.take(max))
          ListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            leading: Icon(
              song.wasSkipped
                  ? Icons.skip_next
                  : song.reason == 'interrupted'
                  ? Icons.warning_amber
                  : Icons.music_note,
              size: 20,
              color: song.wasSkipped ? Colors.orangeAccent : null,
            ),
            title: Text(
              song.artists.isEmpty
                  ? song.name
                  : '${song.name} — ${song.artists}',
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodyMedium,
            ),
            subtitle: Text(
              song.describe(formatMs),
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 11, color: Colors.white60),
            ),
            onTap: song.trackId.isEmpty
                ? null
                : () => openTrackId(song.trackId),
          ),
      ],
    );
  }
}
