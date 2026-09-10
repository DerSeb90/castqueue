import 'package:http/http.dart' as http;
import 'package:xml/xml.dart';

import 'sonos_device.dart';

/// Minimal UPnP SOAP client for a single Sonos player.
class SoapClient {
  SoapClient(this.baseUri, {http.Client? client, this.timeout = const Duration(seconds: 5)})
      : _client = client ?? http.Client();

  final Uri baseUri;
  final http.Client _client;
  final Duration timeout;

  /// Calls [action] on [serviceType] at [controlPath]; returns the response
  /// argument elements (name → text) from `<u:…Response>`.
  Future<Map<String, String>> call({
    required String controlPath,
    required String serviceType,
    required String action,
    Map<String, String> args = const {},
  }) async {
    final body = buildSoapEnvelope(serviceType: serviceType, action: action, args: args);
    http.Response res;
    try {
      res = await _client
          .post(
            baseUri.replace(path: controlPath),
            headers: {
              'Content-Type': 'text/xml; charset="utf-8"',
              'SOAPACTION': '"$serviceType#$action"',
            },
            body: body,
          )
          .timeout(timeout);
    } catch (e) {
      throw SonosException('$action failed: $e');
    }
    return parseSoapResponse(res.body, action: action, statusCode: res.statusCode);
  }

  void close() => _client.close();
}

String buildSoapEnvelope({
  required String serviceType,
  required String action,
  Map<String, String> args = const {},
}) {
  final b = StringBuffer()
    ..write('<?xml version="1.0" encoding="utf-8"?>')
    ..write('<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" ')
    ..write('s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">')
    ..write('<s:Body><u:$action xmlns:u="$serviceType">');
  for (final e in args.entries) {
    b.write('<${e.key}>${xmlEscape(e.value)}</${e.key}>');
  }
  b.write('</u:$action></s:Body></s:Envelope>');
  return b.toString();
}

/// Parses a SOAP response; throws [SonosException] on faults.
Map<String, String> parseSoapResponse(String body, {required String action, int statusCode = 200}) {
  XmlDocument doc;
  try {
    doc = XmlDocument.parse(body);
  } catch (e) {
    throw SonosException('$action: invalid SOAP response (HTTP $statusCode)');
  }
  final fault = doc.findAllElements('Fault', namespaceUri: '*').firstOrNull;
  if (fault != null || statusCode >= 400) {
    int? code;
    String? desc;
    if (fault != null) {
      final codeText = fault.findAllElements('errorCode', namespaceUri: '*').firstOrNull?.innerText.trim();
      code = codeText == null ? null : int.tryParse(codeText);
      desc = fault.findAllElements('errorDescription', namespaceUri: '*').firstOrNull?.innerText.trim();
      desc ??= fault.findAllElements('faultstring', namespaceUri: '*').firstOrNull?.innerText.trim();
    }
    throw SonosException('$action: ${desc ?? 'UPnP error'} (HTTP $statusCode)', code);
  }
  final resp = doc.findAllElements('${action}Response', namespaceUri: '*').firstOrNull;
  if (resp == null) return const {};
  final out = <String, String>{};
  for (final child in resp.childElements) {
    out[child.localName] = child.innerText;
  }
  return out;
}

String xmlEscape(String s) => s
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;')
    .replaceAll('"', '&quot;')
    .replaceAll("'", '&apos;');

String xmlUnescape(String s) => s
    .replaceAll('&lt;', '<')
    .replaceAll('&gt;', '>')
    .replaceAll('&quot;', '"')
    .replaceAll('&apos;', "'")
    .replaceAll('&#39;', "'")
    .replaceAll('&amp;', '&');
