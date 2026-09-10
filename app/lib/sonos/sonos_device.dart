/// A Sonos zone player (or the coordinator of a zone group) in the LAN.
class SonosDevice {
  const SonosDevice({
    required this.uuid,
    required this.roomName,
    required this.host,
    this.port = 1400,
    this.modelName = '',
  });

  /// e.g. `RINCON_000E58XXXXXX01400` (without the `uuid:` prefix).
  final String uuid;

  /// ZoneName, e.g. "Wohnzimmer"; for groups "Wohnzimmer (+1)".
  final String roomName;

  /// IPv4 address.
  final String host;
  final int port;

  /// e.g. "Sonos One".
  final String modelName;

  Uri get baseUri => Uri(scheme: 'http', host: host, port: port);

  SonosDevice copyWith({String? roomName, String? modelName}) => SonosDevice(
        uuid: uuid,
        roomName: roomName ?? this.roomName,
        host: host,
        port: port,
        modelName: modelName ?? this.modelName,
      );

  @override
  bool operator ==(Object other) => other is SonosDevice && other.uuid == uuid;

  @override
  int get hashCode => uuid.hashCode;

  @override
  String toString() => 'SonosDevice($roomName @ $host, $uuid)';
}

/// Raised for SOAP faults and transport-level failures talking to a player.
class SonosException implements Exception {
  const SonosException(this.message, [this.upnpErrorCode]);

  final String message;

  /// UPnP error code from `<errorCode>` (e.g. 701, 711), `null` if not a SOAP fault.
  final int? upnpErrorCode;

  @override
  String toString() => upnpErrorCode == null
      ? 'SonosException: $message'
      : 'SonosException($upnpErrorCode): $message';
}
