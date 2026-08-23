import 'package:url_launcher/url_launcher.dart';

import '../models/track.dart';

/// Shows the track's Spotify page without handing it to the Spotify app.
///
/// `open.spotify.com/track/…` is an Android App Link: the phone opens the
/// Spotify app, which starts *playing* the track (on the host phone that
/// hijacks the party). The embed page shows the same card with an explicit
/// play button, is not claimed by the app, and opens in a browser view.
Future<bool> openInSpotify(Track track) => launchUrl(
  Uri.parse('https://open.spotify.com/embed/track/${track.id}'),
  mode: LaunchMode.inAppBrowserView,
  webOnlyWindowName: '_blank',
);
