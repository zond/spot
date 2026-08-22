import 'package:url_launcher/url_launcher.dart';

import '../models/track.dart';

/// Opens the track's Spotify page — the Spotify app takes over when it is
/// installed (app links), otherwise open.spotify.com in a tab.
Future<bool> openInSpotify(Track track) => launchUrl(
      Uri.parse(track.spotifyUrl),
      mode: LaunchMode.externalApplication,
    );
