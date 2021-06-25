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
    var pac =
        list.where((element) => element.type == VKProxyType.httpRfc).join('; ');

    client.findProxy = (Uri uri) => pac;
  }

  static void trustify(
      Set<VKProxyCertificate> certificates, HttpClient client) {
    if (certificates.isNotEmpty) {
      client.badCertificateCallback = (certificate, domain, port) {
        var hash =
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
    void Function()? onConnectionEstablished,
  }) async {
    if (proxies.isEmpty) proxies.add(VKProxy('', 0, type: VKProxyType.none));

    var origin = url.host;
    var lastError;

    for (var proxy in proxies) {
      try {
        if (proxy != null) {
          if (proxy.type == VKProxyType.httpTransparent) {
            url = url.replace(host: proxy.host);
          }
        }

        var request = await client.openUrl(
          method,
          url,
        );

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
          bodyFields.forEach((key, value) {
            queryBody.add(
              Uri.encodeQueryComponent(key) +
                  '=' +
                  Uri.encodeQueryComponent(value.toString()),
            );
          });

          body = queryBody.join('&');
        }

        if (body != null) {
          final encodedBody = utf8.encode(body);
          request.headers.set('Content-Length', encodedBody.length.toString());
          request.write(body);
        }

        if (onConnectionEstablished != null) Timer.run(onConnectionEstablished);

        var response = await request.close();

        return response;
      } catch (e) {
        if (failedProxies != null) failedProxies.add(proxy);
        lastError = e;
      }
    }

    throw lastError;
  }

  static Future<Duration> pingVK(
    HttpClient client, {
    Duration? timeout,
    VKProxy? proxy,
  }) async {
    const pingHash = 'e8a80fae4cf9dc69cd12a35e7eadb8f8';
    const target = 'https://vk.com/ping.txt';

    var start = DateTime.now();

    if (timeout != null) client.connectionTimeout = timeout;

    var request = await VKGetUtils.request(
      client,
      Uri.parse(target),
      proxies: {proxy},
      method: 'GET',
    );
    var result = await responseToString(request);

    if (_generateMd5(result.trim()) != pingHash) {
      throw Exception(
          "Ping hash doesn\'t match\n\n${result.trim()}\n\n${_generateMd5(result.trim())} != $pingHash");
    }

    return DateTime.now().difference(start);
  }

  static Future<List<int>> responseToIntList(
      HttpClientResponse response) async {
    final responseData = <int>[];
    await for (var i in response) {
      responseData.addAll(i);
    }
    return responseData;
  }

  static Future<String> responseToString(HttpClientResponse response) async {
    final responseData = await VKGetUtils.responseToIntList(response);
    return utf8.decode(responseData);
  }

  static Future<VKProxyList> getProxyList({
    int sdk = 26,
    String version = '8.0.0',
    String device = 'Redmi Note 3',
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
  "appVersion": "6.11",
  "countryCode": "US",
  "sdkVersion": "19.1.4",
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

    var client = HttpClient();
    var request = await client.postUrl(Uri.parse(url));

    headers.forEach((key, value) {
      request.headers.add(key, value);
    });

    request.write(body);

    final response = await request.close();
    final responseData = <int>[];
    await for (var i in response) {
      responseData.addAll(i);
    }

    final result = utf8.decode(responseData);

    final Map<String, dynamic> json = jsonDecode(result.toString());

    final Map<String, dynamic> proxyRaw =
        jsonDecode(json['entries']['config_network_proxy'])['data'];

    final List<String> ips = proxyRaw['ip'].cast<String>(),
        weight = proxyRaw['weight'].cast<String>();

    final paired = <String, int>{};

    ips.asMap().forEach((key, ip) {
      paired[ip] = int.parse(weight.elementAt(key));
    });

    ips.sort((a, b) {
      final varA = paired[a], varB = paired[b];
      if (varA == null || varB == null) return 0;

      return varB - varA;
    });

    var proxy = ips
        .map((p) => VKProxy(p, port, type: VKProxyType.httpTransparent))
        .toSet();

    var certs = <VKProxyCertificate>{};
    try {
      final Map<String, dynamic> certificatesRaw =
          jsonDecode(json['entries']['config_network_proxy_certs']);
      final List<dynamic> certsList = certificatesRaw['certs'];

      certs = certsList
          .map((element) => VKProxyCertificate(
                VKProxyCertificateType.pem,
                X509Utils.x509CertificateFromPem(element['cert']).md5Thumbprint,
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
    var options = Uri.parse(host);
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

  static dynamic parseJson(s) => jsonDecode(s);
}

String _randomString(int length) {
  const chars = 'AaBbCcDdEeFfGgHhIiJjKkLlMmNnOoPpQqRrSsTtUuVvWwXxYyZz';
  var rnd = Random();

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
