import 'package:spotify_sdk/spotify_sdk.dart';

import '../config.dart';
import 'host_settings.dart';

/// What the host controller needs from a Spotify player.
abstract interface class HostPlayer {
  Future<void> connect();
  Future<void> disconnect();
  Stream<PlayerState> get states;
  Stream<ConnectionStatus> get connection;
  Future<PlayerState?> state();
  Future<void> play(String uri);
  Future<void> pause();
  Future<void> resume();
}

/// Drives the Spotify app installed on this phone through App Remote. The
/// Spotify app does the streaming (and keeps doing so with the screen off).
class AppRemotePlayer implements HostPlayer {
  @override
  Future<void> connect() async {
    if (!await SpotifySdk.isSpotifyInstalled()) {
      throw StateError('The Spotify app is not installed on this phone');
    }
    final ok = await SpotifySdk.connectToSpotifyRemote(
      clientId: HostSettings.clientId,
      redirectUrl: Config.spotifyRedirectUri,
      playerName: 'Spot',
    );
    if (!ok) throw StateError('Could not connect to the Spotify app');
    // Single-track playback must not loop or shuffle; the scheduler decides
    // what comes next.
    try {
      await SpotifySdk.setRepeatMode(repeatMode: SpotifyRepeatMode.off);
    } catch (_) {}
    try {
      await SpotifySdk.setShuffle(shuffle: false);
    } catch (_) {}
  }

  @override
  Future<void> disconnect() => SpotifySdk.disconnect();

  @override
  Stream<PlayerState> get states => SpotifySdk.subscribePlayerState();

  @override
  Stream<ConnectionStatus> get connection =>
      SpotifySdk.subscribeConnectionStatus();

  @override
  Future<PlayerState?> state() => SpotifySdk.getPlayerState();

  @override
  Future<void> play(String uri) => SpotifySdk.play(spotifyUri: uri);

  @override
  Future<void> pause() => SpotifySdk.pause();

  @override
  Future<void> resume() => SpotifySdk.resume();
}
