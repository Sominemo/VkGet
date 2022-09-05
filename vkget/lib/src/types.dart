import 'dart:async';
import 'dart:convert';
import 'dart:io';

enum VKProxyType { httpRfc, httpTransparent, none }

enum VKProxyCertificateType { pem, none, free }

class VKProxyCertificate {
  const VKProxyCertificate(this.type, [this.value]);

  final String? value;
  final VKProxyCertificateType type;

  @override
  String toString() {
    return '$type ${value ?? ''}';
  }

  @override
  bool operator ==(Object other) {
    if (other is! VKProxyCertificate) return false;
    return value == other.value && type == other.type;
  }

  @override
  int get hashCode => value.hashCode * 32 + type.hashCode * 33;
}

class VKProxy {
  const VKProxy(
    this.host,
    this.port, {
    this.username,
    this.password,
    this.type = VKProxyType.httpRfc,
  });

  final String? host, username, password;
  final int port;
  final VKProxyType type;

  @override
  String toString() {
    if (type == VKProxyType.none) return 'DIRECT';

    return 'PROXY ${username != null ? '${username!}${password != null ? ':$password' : ''}@' : ''}$host:$port';
  }

  @override
  bool operator ==(Object other) {
    if (other is! VKProxy) return false;
    return host == other.host &&
        port == other.port &&
        username == other.username &&
        password == other.password &&
        type == other.type;
  }

  @override
  int get hashCode =>
      host.hashCode * 31 +
      port.hashCode * 32 +
      username.hashCode * 33 +
      password.hashCode * 34 +
      type.hashCode * 35;
}

class VKGetRequest {
  VKGetRequest(
    this.method,
    this.data,
    this.domain,
    this.isOauth,
    this.isTraced,
    this.lazyInterpretation,
  ) : completer = Completer();

  final Completer<VKGetResponse> completer;
  final String method, domain;
  final Map<String, dynamic> data;
  final bool isOauth;
  final bool isTraced;
  final bool lazyInterpretation;

  @override
  int get hashCode =>
      method.hashCode * 31 +
      data.hashCode * 32 +
      domain.hashCode * 33 +
      (isOauth ? 1 : 0) * 34 +
      (isTraced ? 1 : 0) * 35 +
      (lazyInterpretation ? 1 : 0) * 36;

  @override
  bool operator ==(Object other) {
    if (other is! VKGetRequest) return false;

    if (method != other.method) return false;
    if (data != other.data) return false;
    if (domain != other.domain) return false;
    if (isOauth != other.isOauth) return false;
    if (isTraced != other.isTraced) return false;
    if (lazyInterpretation != other.lazyInterpretation) return false;

    return true;
  }
}

class VKGetResponse {
  VKGetResponse(
    this.response,
    this.body,
    this.allowInterpretation,
  );

  final HttpClientResponse response;
  final String body;
  final void Function(bool value)? allowInterpretation;
  dynamic asJson() => jsonDecode(body);
}

class VKGetValidationResult {
  VKGetValidationResult(this.isValid, {this.code});

  final bool isValid;
  final String? code;
}
