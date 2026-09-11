/// Data models mirroring `docs/API.md`.
library;

DateTime? _dt(Object? v) {
  if (v is String && v.isNotEmpty) return DateTime.tryParse(v)?.toUtc();
  return null;
}

String? _dts(DateTime? v) => v?.toUtc().toIso8601String();

int _int(Object? v, [int def = 0]) {
  if (v is int) return v;
  if (v is num) return v.toInt();
  if (v is String) return int.tryParse(v) ?? def;
  return def;
}

bool _bool(Object? v, [bool def = false]) => v is bool ? v : def;

String _str(Object? v, [String def = '']) => v is String ? v : def;

List<String> _strList(Object? v) => v is List ? [for (final e in v) if (e is String && e.isNotEmpty) e] : const [];

class Podcast {
  const Podcast({
    required this.id,
    required this.title,
    required this.feedUrl,
    this.description = '',
    this.author = '',
    this.imageUrl = '',
    this.website = '',
    this.autoEnqueue = true,
    this.hasAuth = false,
    this.episodeCount = 0,
    this.lastRefreshedAt,
    this.lastError = '',
    this.language = '',
    this.copyright = '',
    this.categories = const [],
    this.explicit = false,
    this.podcastType = '',
    this.ownerName = '',
    this.createdAt,
    this.updatedAt,
  });

  final String id;
  final String title;
  final String feedUrl;
  final String description;
  final String author;
  final String imageUrl;
  final String website;
  final bool autoEnqueue;
  final bool hasAuth;
  final int episodeCount;
  final DateTime? lastRefreshedAt;
  final String lastError;
  final String language;
  final String copyright;
  final List<String> categories;
  final bool explicit;

  /// "episodic", "serial" or "".
  final String podcastType;
  final String ownerName;
  final DateTime? createdAt;
  final DateTime? updatedAt;

  factory Podcast.fromJson(Map<String, dynamic> j) => Podcast(
        id: _str(j['id']),
        title: _str(j['title']),
        feedUrl: _str(j['feed_url']),
        description: _str(j['description']),
        author: _str(j['author']),
        imageUrl: _str(j['image_url']),
        website: _str(j['website']),
        autoEnqueue: _bool(j['auto_enqueue'], true),
        hasAuth: _bool(j['has_auth']),
        episodeCount: _int(j['episode_count']),
        lastRefreshedAt: _dt(j['last_refreshed_at']),
        lastError: _str(j['last_error']),
        language: _str(j['language']),
        copyright: _str(j['copyright']),
        categories: _strList(j['categories']),
        explicit: _bool(j['explicit']),
        podcastType: _str(j['podcast_type']),
        ownerName: _str(j['owner_name']),
        createdAt: _dt(j['created_at']),
        updatedAt: _dt(j['updated_at']),
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'title': title,
        'feed_url': feedUrl,
        'description': description,
        'author': author,
        'image_url': imageUrl,
        'website': website,
        'auto_enqueue': autoEnqueue,
        'has_auth': hasAuth,
        'episode_count': episodeCount,
        'last_refreshed_at': _dts(lastRefreshedAt),
        'last_error': lastError,
        'language': language,
        'copyright': copyright,
        'categories': categories,
        'explicit': explicit,
        'podcast_type': podcastType,
        'owner_name': ownerName,
        'created_at': _dts(createdAt),
        'updated_at': _dts(updatedAt),
      };

  Podcast copyWith({bool? autoEnqueue, bool? hasAuth, String? title}) => Podcast(
        id: id,
        title: title ?? this.title,
        feedUrl: feedUrl,
        description: description,
        author: author,
        imageUrl: imageUrl,
        website: website,
        autoEnqueue: autoEnqueue ?? this.autoEnqueue,
        hasAuth: hasAuth ?? this.hasAuth,
        episodeCount: episodeCount,
        lastRefreshedAt: lastRefreshedAt,
        lastError: lastError,
        language: language,
        copyright: copyright,
        categories: categories,
        explicit: explicit,
        podcastType: podcastType,
        ownerName: ownerName,
        createdAt: createdAt,
        updatedAt: updatedAt,
      );
}

class Episode {
  const Episode({
    required this.id,
    required this.podcastId,
    this.podcastTitle = '',
    this.podcastImageUrl = '',
    this.guid = '',
    this.title = '',
    this.description = '',
    this.link = '',
    this.imageUrl = '',
    this.mediaUrl = '',
    this.streamUrl = '',
    this.mediaType = '',
    this.mediaSize = 0,
    this.durationMs = 0,
    this.publishedAt,
    this.season = 0,
    this.episodeNumber = 0,
    this.episodeType = '',
    this.explicit = false,
    this.author = '',
    this.positionMs = 0,
    this.played = false,
    this.progressUpdatedAt,
    this.inQueue = false,
    this.updatedAt,
  });

  final String id;
  final String podcastId;
  final String podcastTitle;
  final String podcastImageUrl;
  final String guid;
  final String title;
  final String description;
  final String link;
  final String imageUrl;
  final String mediaUrl;
  final String streamUrl;
  final String mediaType;
  final int mediaSize;
  final int durationMs;
  final DateTime? publishedAt;

  /// `<itunes:season>` / `<itunes:episode>`, 0 when absent.
  final int season;
  final int episodeNumber;

  /// "full", "trailer", "bonus" or "".
  final String episodeType;
  final bool explicit;
  final String author;
  final int positionMs;
  final bool played;
  final DateTime? progressUpdatedAt;
  final bool inQueue;
  final DateTime? updatedAt;

  /// Best artwork: episode image, else podcast image.
  String get artworkUrl => imageUrl.isNotEmpty ? imageUrl : podcastImageUrl;

  /// "S2E14", "S2", "E14" or "" for list prefixes.
  String get seasonEpisodeLabel {
    if (season > 0 && episodeNumber > 0) return 'S${season}E$episodeNumber';
    if (season > 0) return 'S$season';
    if (episodeNumber > 0) return 'E$episodeNumber';
    return '';
  }

  Duration get duration => Duration(milliseconds: durationMs);
  Duration get position => Duration(milliseconds: positionMs);

  /// 0..1 progress for the tile bar.
  double get progressFraction {
    if (played) return 1;
    if (durationMs <= 0 || positionMs <= 0) return 0;
    return (positionMs / durationMs).clamp(0, 1).toDouble();
  }

  factory Episode.fromJson(Map<String, dynamic> j) => Episode(
        id: _str(j['id']),
        podcastId: _str(j['podcast_id']),
        podcastTitle: _str(j['podcast_title']),
        podcastImageUrl: _str(j['podcast_image_url']),
        guid: _str(j['guid']),
        title: _str(j['title']),
        description: _str(j['description']),
        link: _str(j['link']),
        imageUrl: _str(j['image_url']),
        mediaUrl: _str(j['media_url']),
        streamUrl: _str(j['stream_url']),
        mediaType: _str(j['media_type']),
        mediaSize: _int(j['media_size']),
        durationMs: _int(j['duration_ms']),
        publishedAt: _dt(j['published_at']),
        season: _int(j['season']),
        episodeNumber: _int(j['episode_number']),
        episodeType: _str(j['episode_type']),
        explicit: _bool(j['explicit']),
        author: _str(j['author']),
        positionMs: _int(j['position_ms']),
        played: _bool(j['played']),
        progressUpdatedAt: _dt(j['progress_updated_at']),
        inQueue: _bool(j['in_queue']),
        updatedAt: _dt(j['updated_at']),
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'podcast_id': podcastId,
        'podcast_title': podcastTitle,
        'podcast_image_url': podcastImageUrl,
        'guid': guid,
        'title': title,
        'description': description,
        'link': link,
        'image_url': imageUrl,
        'media_url': mediaUrl,
        'stream_url': streamUrl,
        'media_type': mediaType,
        'media_size': mediaSize,
        'duration_ms': durationMs,
        'published_at': _dts(publishedAt),
        'season': season,
        'episode_number': episodeNumber,
        'episode_type': episodeType,
        'explicit': explicit,
        'author': author,
        'position_ms': positionMs,
        'played': played,
        'progress_updated_at': _dts(progressUpdatedAt),
        'in_queue': inQueue,
        'updated_at': _dts(updatedAt),
      };

  Episode copyWith({
    int? positionMs,
    int? durationMs,
    bool? played,
    DateTime? progressUpdatedAt,
    bool? inQueue,
    DateTime? updatedAt,
  }) =>
      Episode(
        id: id,
        podcastId: podcastId,
        podcastTitle: podcastTitle,
        podcastImageUrl: podcastImageUrl,
        guid: guid,
        title: title,
        description: description,
        link: link,
        imageUrl: imageUrl,
        mediaUrl: mediaUrl,
        streamUrl: streamUrl,
        mediaType: mediaType,
        mediaSize: mediaSize,
        durationMs: durationMs ?? this.durationMs,
        publishedAt: publishedAt,
        season: season,
        episodeNumber: episodeNumber,
        episodeType: episodeType,
        explicit: explicit,
        author: author,
        positionMs: positionMs ?? this.positionMs,
        played: played ?? this.played,
        progressUpdatedAt: progressUpdatedAt ?? this.progressUpdatedAt,
        inQueue: inQueue ?? this.inQueue,
        updatedAt: updatedAt ?? this.updatedAt,
      );
}

/// `GET /api/queue` response (full episode objects).
class QueueState {
  const QueueState({required this.version, required this.items});
  final int version;
  final List<Episode> items;

  factory QueueState.fromJson(Map<String, dynamic> j) => QueueState(
        version: _int(j['version']),
        items: [
          for (final e in (j['items'] as List? ?? const []))
            Episode.fromJson(e as Map<String, dynamic>),
        ],
      );
}

/// Queue as ids (sync payload / local cache).
class QueueIds {
  const QueueIds({required this.version, required this.episodeIds});
  final int version;
  final List<String> episodeIds;

  factory QueueIds.fromJson(Map<String, dynamic> j) => QueueIds(
        version: _int(j['version']),
        episodeIds: [
          for (final id in (j['episode_ids'] as List? ?? const [])) id.toString(),
        ],
      );

  Map<String, dynamic> toJson() => {'version': version, 'episode_ids': episodeIds};
}

class Settings {
  const Settings({
    this.autoRemovePlayed = true,
    this.refreshIntervalMinutes = 30,
    this.autoEnqueueDefault = true,
  });
  final bool autoRemovePlayed;
  final int refreshIntervalMinutes;
  final bool autoEnqueueDefault;

  factory Settings.fromJson(Map<String, dynamic> j) => Settings(
        autoRemovePlayed: _bool(j['auto_remove_played'], true),
        refreshIntervalMinutes: _int(j['refresh_interval_minutes'], 30),
        autoEnqueueDefault: _bool(j['auto_enqueue_default'], true),
      );

  Map<String, dynamic> toJson() => {
        'auto_remove_played': autoRemovePlayed,
        'refresh_interval_minutes': refreshIntervalMinutes,
        'auto_enqueue_default': autoEnqueueDefault,
      };
}

class SyncResponse {
  const SyncResponse({
    required this.serverTime,
    required this.podcasts,
    required this.podcastsDeleted,
    required this.episodes,
    required this.episodesDeleted,
    required this.queue,
    required this.settings,
  });
  final DateTime serverTime;
  final List<Podcast> podcasts;
  final List<String> podcastsDeleted;
  final List<Episode> episodes;
  final List<String> episodesDeleted;
  final QueueIds queue;
  final Settings settings;

  factory SyncResponse.fromJson(Map<String, dynamic> j) => SyncResponse(
        serverTime: _dt(j['server_time']) ?? DateTime.now().toUtc(),
        podcasts: [
          for (final p in (j['podcasts'] as List? ?? const []))
            Podcast.fromJson(p as Map<String, dynamic>),
        ],
        podcastsDeleted: [
          for (final id in (j['podcasts_deleted'] as List? ?? const [])) id.toString(),
        ],
        episodes: [
          for (final e in (j['episodes'] as List? ?? const []))
            Episode.fromJson(e as Map<String, dynamic>),
        ],
        episodesDeleted: [
          for (final id in (j['episodes_deleted'] as List? ?? const [])) id.toString(),
        ],
        queue: QueueIds.fromJson((j['queue'] as Map<String, dynamic>?) ?? const {}),
        settings: Settings.fromJson((j['settings'] as Map<String, dynamic>?) ?? const {}),
      );
}

class SearchResult {
  const SearchResult({
    required this.title,
    required this.author,
    required this.feedUrl,
    required this.imageUrl,
    this.genres = const [],
    this.episodeCount = 0,
    this.latestReleaseAt,
    this.itunesUrl = '',
    this.explicit = false,
    this.country = '',
  });
  final String title;
  final String author;
  final String feedUrl;
  final String imageUrl;
  final List<String> genres;
  final int episodeCount;
  final DateTime? latestReleaseAt;
  final String itunesUrl;
  final bool explicit;
  final String country;

  factory SearchResult.fromJson(Map<String, dynamic> j) => SearchResult(
        title: _str(j['title']),
        author: _str(j['author']),
        feedUrl: _str(j['feed_url']),
        imageUrl: _str(j['image_url']),
        genres: _strList(j['genres']),
        episodeCount: _int(j['episode_count']),
        latestReleaseAt: _dt(j['latest_release_at']),
        itunesUrl: _str(j['itunes_url']),
        explicit: _bool(j['explicit']),
        country: _str(j['country']),
      );
}

class DeviceInfo {
  const DeviceInfo({
    required this.id,
    required this.name,
    this.createdAt,
    this.lastSeenAt,
    this.current = false,
  });
  final String id;
  final String name;
  final DateTime? createdAt;
  final DateTime? lastSeenAt;
  final bool current;

  factory DeviceInfo.fromJson(Map<String, dynamic> j) => DeviceInfo(
        id: _str(j['id']),
        name: _str(j['name']),
        createdAt: _dt(j['created_at']),
        lastSeenAt: _dt(j['last_seen_at']),
        current: _bool(j['current']),
      );
}

class LoginResponse {
  const LoginResponse({required this.token, required this.deviceId, required this.streamToken});
  final String token;
  final String deviceId;
  final String streamToken;

  factory LoginResponse.fromJson(Map<String, dynamic> j) => LoginResponse(
        token: _str(j['token']),
        deviceId: _str(j['device_id']),
        streamToken: _str(j['stream_token']),
      );
}

class MeInfo {
  const MeInfo({
    required this.username,
    required this.deviceId,
    required this.deviceName,
    required this.streamToken,
    required this.publicUrl,
    this.serverTime,
    this.serverVersion = '',
  });
  final String username;
  final String deviceId;
  final String deviceName;
  final String streamToken;
  final String publicUrl;
  final DateTime? serverTime;
  final String serverVersion;

  factory MeInfo.fromJson(Map<String, dynamic> j) => MeInfo(
        username: _str(j['username']),
        deviceId: _str(j['device_id']),
        deviceName: _str(j['device_name']),
        streamToken: _str(j['stream_token']),
        publicUrl: _str(j['public_url']),
        serverTime: _dt(j['server_time']),
        serverVersion: _str(j['server_version']),
      );
}

/// A pending/outgoing progress update (`PUT /api/episodes/{id}/progress`).
class ProgressUpdate {
  const ProgressUpdate({
    required this.episodeId,
    required this.positionMs,
    required this.updatedAt,
    this.durationMs,
    this.played,
  });
  final String episodeId;
  final int positionMs;
  final int? durationMs;
  final bool? played;
  final DateTime updatedAt;

  Map<String, dynamic> toJson({bool withId = false}) => {
        if (withId) 'episode_id': episodeId,
        'position_ms': positionMs,
        if (durationMs != null) 'duration_ms': durationMs,
        if (played != null) 'played': played,
        'updated_at': updatedAt.toUtc().toIso8601String(),
      };

  factory ProgressUpdate.fromJson(Map<String, dynamic> j) => ProgressUpdate(
        episodeId: _str(j['episode_id']),
        positionMs: _int(j['position_ms']),
        durationMs: j['duration_ms'] == null ? null : _int(j['duration_ms']),
        played: j['played'] is bool ? j['played'] as bool : null,
        updatedAt: _dt(j['updated_at']) ?? DateTime.now().toUtc(),
      );
}

class RefreshResult {
  const RefreshResult({required this.refreshed, required this.errors});
  final int refreshed;
  final int errors;
  factory RefreshResult.fromJson(Map<String, dynamic> j) =>
      RefreshResult(refreshed: _int(j['refreshed']), errors: _int(j['errors']));
}

class OpmlImportResult {
  const OpmlImportResult({required this.added, required this.skipped, required this.failed});
  final int added;
  final int skipped;
  final List<String> failed;
  factory OpmlImportResult.fromJson(Map<String, dynamic> j) => OpmlImportResult(
        added: _int(j['added']),
        skipped: _int(j['skipped']),
        failed: [for (final f in (j['failed'] as List? ?? const [])) f.toString()],
      );
}
