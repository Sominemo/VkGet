import 'dart:async';
import 'dart:io';
import 'dart:math' show Random;
import 'dart:convert' show jsonDecode, utf8;
import 'package:basic_utils/basic_utils.dart' show X509Utils;
import 'package:crypto/crypto.dart' show md5;

import 'types.dart';

class VKProxyList {
  VKProxyList(this.proxy, this.certificates);
  final Set<VKProxy> proxy;
  final Set<VKProxyCertificate> certificates;
}

class VKGetUtils {
  static void proxify(HttpClient client, List<VKProxy> list) {
    final pac =
        list.where((element) => element.type == VKProxyType.httpRfc).join('; ');

    client.findProxy = (Uri uri) => pac;
  }

  static void trustify(
      Set<VKProxyCertificate> certificates, HttpClient client) {
    if (certificates.isNotEmpty) {
      client.badCertificateCallback = (certificate, domain, port) {
        final hash =
            X509Utils.x509CertificateFromPem(certificate.pem).md5Thumbprint;

        return certificates.any((cert) {
          if (cert.type == VKProxyCertificateType.pem) {
            return cert.value == hash;
          }
          if (cert.type == VKProxyCertificateType.free) {
            return true;
          }
          return false;
        });
      };
    }
  }

  static Future<HttpClientResponse> request(
    HttpClient client,
    Uri url, {
    required Set<VKProxy?> proxies,
    String method = 'POST',
    String? body,
    Map<String, dynamic>? bodyFields,
    Map<String, String>? headers,
    List<VKProxy?>? failedProxies,
    Duration? timeout,
    void Function()? onConnectionEstablished,
  }) async {
    if (proxies.isEmpty) proxies.add(VKProxy('', 0, type: VKProxyType.none));

    final origin = url.host;
    Object? lastError;

    if (timeout != null) {
      client.connectionTimeout = timeout;
      client.idleTimeout = timeout;
    }

    HttpClientRequest? ongoingRequest;
    for (final proxy in proxies) {
      try {
        final pureRequest = Future<HttpClientResponse>(() async {
          if (proxy != null) {
            if (proxy.type == VKProxyType.httpTransparent) {
              url = url.replace(host: proxy.host);
            }
          }

          final request = await client.openUrl(
            method,
            url,
          );
          ongoingRequest = request;

          if (proxy != null && proxy.type == VKProxyType.httpTransparent) {
            request.headers.add('Host', origin, preserveHeaderCase: true);
          }

          if (headers != null) {
            headers.forEach((key, value) {
              request.headers.add(key, value);
            });
          }

          if (bodyFields != null) {
            request.headers
                .add('Content-Type', 'application/x-www-form-urlencoded');

            final queryBody = <String>[];
            bodyFields.forEach((key, dynamic value) {
              queryBody.add(
                Uri.encodeQueryComponent(key) +
                    '=' +
                    Uri.encodeQueryComponent(value.toString()),
              );
            });

            body = queryBody.join('&');
          }

          if (body != null) {
            final encodedBody = utf8.encode(body!);
            request.headers
                .set('Content-Length', encodedBody.length.toString());
            request.write(body);
          }

          if (onConnectionEstablished != null) {
            Timer.run(onConnectionEstablished);
          }

          final response = await request.close();

          if (timeout != null) {
            client.connectionTimeout = null;
            client.idleTimeout = Duration(seconds: 15);
          }

          return response;
        });

        HttpClientResponse res;

        if (timeout != null) {
          res = await pureRequest.timeout(timeout, onTimeout: () {
            ongoingRequest?.close();
            throw TimeoutException('Connection probe was running for too long');
          });
        } else {
          res = await pureRequest;
        }
        return res;
      } catch (e) {
        if (failedProxies != null) failedProxies.add(proxy);
        lastError = e;
      }
    }

    if (timeout != null) {
      client.connectionTimeout = null;
      client.idleTimeout = Duration(seconds: 15);
    }

    throw lastError!;
  }

  static Future<Duration> pingVK(
    HttpClient client, {
    Duration? timeout,
    VKProxy? proxy,
  }) async {
    const pingHash = 'e8a80fae4cf9dc69cd12a35e7eadb8f8';
    const target = 'https://vk.com/ping.txt';

    final start = DateTime.now();

    final request = await VKGetUtils.request(
      client,
      Uri.parse(target),
      proxies: {proxy},
      method: 'GET',
      timeout: timeout,
    );
    final result = await responseToString(request);

    if (_generateMd5(result.trim()) != pingHash) {
      throw Exception(
          "Ping hash doesn't match\n\n${result.trim()}\n\n${_generateMd5(result.trim())} != $pingHash");
    }

    return DateTime.now().difference(start);
  }

  static Future<List<int>> responseToIntList(
      HttpClientResponse response) async {
    final responseData = <int>[];
    await for (final i in response) {
      responseData.addAll(i);
    }
    return responseData;
  }

  static Future<String> responseToString(HttpClientResponse response) async {
    final responseData = await VKGetUtils.responseToIntList(response);
    return utf8.decode(responseData);
  }

  static Future<VKProxyList> getProxyList({
    int? sdk = 26,
    String? version = '8.0.0',
    String? device = 'Redmi Note 3',
  }) async {
    const port = 80;

    const url =
        'https://firebaseremoteconfig.googleapis.com/v1/projects/841415684880/namespaces/firebase:fetch';
    final fid = _randomString(22);

    final body = '''
{
  "platformVersion": "$sdk",
  "appInstanceId": "$fid",
  "packageName": "com.vkontakte.android",
  "appVersion": "7.12",
  "countryCode": "US",
  "sdkVersion": "21.0.1",
  "analyticsUserProperties": {},
  "appId": "1:841415684880:android:632f429381141121",
  "languageCode": "en-US",
  "appInstanceIdToken": "$fid",
  "timeZone": "GMT"
}
''';

    final headers = {
      'X-Goog-Api-Key': 'AIzaSyAvrvAACdzmgDYFM9hvJS88KdSlQsafID0',
      'X-Android-Package': 'com.vkontakte.android',
      'X-Android-Cert': '48761EEF50EE53AFC4CC9C5F10E6BDE7F8F5B82F',
      'X-Google-GFE-Can-Retry': 'yes',
      'Content-Type': 'application/json',
      'Accept': 'application/json',
      'User-Agent': 'Dalvik/2.1.0 (Linux; U; Android $version; $device)',
    };

    final client = HttpClient();
    final request = await client.postUrl(Uri.parse(url));

    headers.forEach((key, value) {
      request.headers.add(key, value);
    });

    request.write(body);

    final response = await request.close();
    final responseData = <int>[];
    await for (final i in response) {
      responseData.addAll(i);
    }

    final result = utf8.decode(responseData);

    final Map<String, dynamic> json =
        jsonDecode(result.toString()) as Map<String, dynamic>;

    final Map<String, dynamic> proxyRaw =
        jsonDecode(json['entries']['config_network_proxy'] as String)['data']
            as Map<String, dynamic>;

    final List<String> ips = (proxyRaw['ip'] as List<dynamic>).cast<String>(),
        weight = (proxyRaw['weight'] as List<dynamic>).cast<String>();

    final paired = <String, int>{};

    ips.asMap().forEach((key, ip) {
      paired[ip] = int.parse(weight.elementAt(key));
    });

    ips.sort((a, b) {
      final varA = paired[a], varB = paired[b];
      if (varA == null || varB == null) return 0;

      return varB - varA;
    });

    final proxy = ips
        .map((p) => VKProxy(p, port, type: VKProxyType.httpTransparent))
        .toSet();

    var certs = <VKProxyCertificate>{};
    try {
      final Map<String, dynamic> certificatesRaw =
          jsonDecode(json['entries']['config_network_proxy_certs'] as String)
              as Map<String, dynamic>;
      final List<dynamic> certsList = certificatesRaw['certs'] as List<dynamic>;

      certs = certsList
          .map((dynamic element) => VKProxyCertificate(
                VKProxyCertificateType.pem,
                X509Utils.x509CertificateFromPem(element['cert'] as String)
                    .md5Thumbprint,
              ))
          .toSet();
    } catch (e) {
      rethrow;
    }

    return VKProxyList(proxy, certs);
  }

  static Future<bool> checkPureInternetConnection({
    String host = 'http://1.1.1.1:53',
    Duration timeout = const Duration(seconds: 10),
  }) async {
    final options = Uri.parse(host);
    Socket? sock;
    try {
      sock = await Socket.connect(
        options.host,
        options.port,
        timeout: timeout,
      );
      sock.destroy();
      return true;
    } catch (e) {
      sock?.destroy();
      return false;
    }
  }

  static dynamic parseJson(String s) => jsonDecode(s);
}

String _randomString(int length) {
  const chars = 'AaBbCcDdEeFfGgHhIiJjKkLlMmNnOoPpQqRrSsTtUuVvWwXxYyZz';
  final rnd = Random();

  return String.fromCharCodes(
    Iterable.generate(
      length,
      (_) => chars.codeUnitAt(
        rnd.nextInt(chars.length),
      ),
    ),
  );
}

String _generateMd5(String input) {
  return md5.convert(utf8.encode(input)).toString();
}
