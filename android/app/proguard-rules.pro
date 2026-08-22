# Spotify App Remote locates the Spotify app through reflection
# (Class.forName("...ReleaseSpotifyLocator").getConstructor().newInstance()).
# The AAR's own rules keep only the class *name*, so R8 strips the constructor
# and isSpotifyInstalled()/connect() claim Spotify isn't installed in release
# builds. Keep the whole SDK.
-keep class com.spotify.** { *; }
-dontwarn com.spotify.**
