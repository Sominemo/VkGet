import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:vkget/src/utils.dart';

import 'types.dart';

class VKGet {
  VKGet(
    this.version,
    this.token, {
    HttpClient? client,
    this.domain = 'https://api.vk.com',
    this.oauthDomain = 'https://oauth.vk.com',
    this.userAgent = 'VKAndroidApp/6.29.1-7369',
    this.errorDetectionKey = 'error',
    void Function(dynamic)? onError,
    Future<bool> Function()? onAccessProblems,
    Future<bool> Function()? onConnectionProblems,
    Future<String> Function(VKGetResponse)? onCaptcha,
    Future<bool> Function(VKGetResponse)? onNeedValidation,
  })  : client = client ?? HttpClient(),
        onError = onError ??
            ((v) {
              print(v);
              throw UnimplementedError('Error resolver not set');
            }),
        onCaptcha = onCaptcha ??
            ((v) {
              print(v);
              throw UnimplementedError('Captcha resolver not set');
            }),
        onAccessProblems = onAccessProblems ??
            (() async {
              print('Access problems detected, but no handler set');
              return false;
            }),
        onConnectionProblems = onConnectionProblems ??
            (() async {
              print('Network connection problems detected, but no handler set');
              return false;
            }),
        onNeedValidation = onNeedValidation ??
            ((v) async {
              print('Validation needed, but no handler set');
              return false;
            });

  final String version;
  String token;
  final String domain, oauthDomain, userAgent, errorDetectionKey;
  final HttpClient client;
  final void Function(dynamic thrown) onError;
  Future<bool> Function() onAccessProblems = () => throw UnimplementedError();
  Future<bool> Function() onConnectionProblems =
      () => throw UnimplementedError();
  Future<String> Function(VKGetResponse r) onCaptcha;
  Future<bool> Function(VKGetResponse r) onNeedValidation;

  void Function(VKGetTrace) onRequestStateChange = (VKGetTrace trace) {};

  final List<_QueueElement> _queue =
      List.generate(3, (_) => _QueueElement(DateTime(1970)), growable: false);

  final List<VKGetRequest> _cart = [];

  Future<VKGetResponse> call(
    String method,
    Map<String, dynamic> data, {
    bool oauth = false,
  }) {
    final request = VKGetRequest(
      method,
      data,
      (oauth ? oauthDomain : domain),
      oauth,
    );
    _cart.add(request);

    onRequestStateChange(
      VKGetTrace(
        state: VKGetTraceRequestState.queued,
        type: (oauth ? VKGetTraceRequestType.oauth : VKGetTraceRequestType.api),
        request: request,
        target: method,
        payload: data,
      ),
    );

    _runner();
    return request.completer.future;
  }

  Future<HttpClientResponse> fetch(
    Uri url, {
    String method = 'GET',
    Map<String, String> headers = const {},
    String? body,
    Map<String, dynamic>? bodyFields,
    String? overrideUserAgent,
  }) async {
    final failedProxies = <VKProxy?>[];
    final requestHeaders = {
      'User-Agent': overrideUserAgent ?? userAgent,
    };
    requestHeaders.addAll(headers);

    onRequestStateChange(
      VKGetTrace(
        state: VKGetTraceRequestState.active,
        type: VKGetTraceRequestType.fetch,
        target: url.toString(),
        payload: {},
      ),
    );

    final result;

    try {
      result = VKGetUtils.request(
        client,
        url,
        method: method,
        failedProxies: failedProxies,
        proxies: proxies,
        headers: requestHeaders,
        body: body,
        bodyFields: bodyFields,
      );

      onRequestStateChange(
        VKGetTrace(
          state: VKGetTraceRequestState.done,
          type: VKGetTraceRequestType.fetch,
          target: url.toString(),
          payload: {},
        ),
      );

      failedProxies.forEach((element) {
        proxies.remove(element);
      });

      return result;
    } catch (e) {
      onRequestStateChange(
        VKGetTrace(
          state: VKGetTraceRequestState.error,
          type: VKGetTraceRequestType.fetch,
          target: url.toString(),
          payload: {},
          statePayload: e,
        ),
      );

      rethrow;
    }
  }

  bool _isRunnerBusy = false;

  Set<VKProxy> proxies = {};

  void _runner({bool isRecursive = false}) async {
    if (_isRunnerBusy && !isRecursive) return;

    _isRunnerBusy = true;

    while (_cart.isNotEmpty) {
      VKGetRequest? r;
      try {
        if (!_queue.any(
          (element) =>
              DateTime.now().difference(element.time) > Duration(seconds: 1) &&
              !element.isBusy,
        )) {
          final delays = _queue
              .map((element) => DateTime.now()
                  .difference(element.isBusy ? DateTime.now() : element.time))
              .toList();
          final max = delays
              .reduce((value, element) => value > element ? value : element);
          Timer(Duration(seconds: 1) - max, () {
            _runner(isRecursive: true);
          });
          return;
        }

        r = _cart.removeAt(0);

        final delays = _queue
            .map((element) => DateTime.now()
                .difference(element.isBusy ? DateTime.now() : element.time))
            .toList();

        final max = delays
            .reduce((value, element) => value > element ? value : element);

        final qIndex = delays.indexOf(max);
        _queue[qIndex].isBusy = true;

        _executeRequest(r, qIndex);
      } catch (e) {
        if (r != null) {
          onRequestStateChange(
            VKGetTrace(
              state: VKGetTraceRequestState.cancelled,
              type: r.isOauth
                  ? VKGetTraceRequestType.oauth
                  : VKGetTraceRequestType.api,
              target: r.method,
              payload: r.data,
              statePayload: e,
            ),
          );
        }

        onError(e);
      }
    }

    _isRunnerBusy = false;
  }

  void _executeRequest(VKGetRequest r, int qIndex) async {
    try {
      var queueLock = false;
      String? lastCaptchaSid;
      String? captchaKey;

      do {
        queueLock = false;
        final failedProxies = <VKProxy?>[];

        onRequestStateChange(
          VKGetTrace(
            state: VKGetTraceRequestState.active,
            type: r.isOauth
                ? VKGetTraceRequestType.oauth
                : VKGetTraceRequestType.api,
            target: r.method,
            payload: r.data,
          ),
        );

        final targetDomain = Uri.parse(r.domain);

        final response = await VKGetUtils.request(
          client,
          targetDomain.replace(
            pathSegments: [...targetDomain.pathSegments, r.method],
          ),
          bodyFields: {
            'v': version,
            'access_token': token,
            if (lastCaptchaSid != null) 'captcha_sid': lastCaptchaSid,
            if (lastCaptchaSid != null) 'captcha_key': captchaKey,
            ...r.data,
          },
          onConnectionEstablished: () {
            _queue[qIndex] = _QueueElement(DateTime.now());
          },
          failedProxies: failedProxies,
          proxies: proxies,
          headers: {'User-Agent': userAgent},
        );

        final result = VKGetResponse(
            response, await VKGetUtils.responseToString(response));

        final json = result.asJson;

        if (json is Map<String, dynamic>) {
          if (json['error'] == 'need_captcha') {
            lastCaptchaSid = json['captcha_sid'];

            onRequestStateChange(
              VKGetTrace(
                state: VKGetTraceRequestState.delayed,
                type: r.isOauth
                    ? VKGetTraceRequestType.oauth
                    : VKGetTraceRequestType.api,
                target: r.method,
                payload: r.data,
                statePayload: json,
              ),
            );

            try {
              captchaKey = await onCaptcha(result);
            } catch (e) {
              onRequestStateChange(
                VKGetTrace(
                  state: VKGetTraceRequestState.cancelled,
                  type: r.isOauth
                      ? VKGetTraceRequestType.oauth
                      : VKGetTraceRequestType.api,
                  target: r.method,
                  payload: r.data,
                  statePayload: e,
                ),
              );
              rethrow;
            }
            queueLock = true;
            continue;
          } else if (json['error'] == 'need_validation') {
            onRequestStateChange(
              VKGetTrace(
                state: VKGetTraceRequestState.delayed,
                type: r.isOauth
                    ? VKGetTraceRequestType.oauth
                    : VKGetTraceRequestType.api,
                target: r.method,
                payload: r.data,
                statePayload: json,
              ),
            );

            try {
              if (!(await onNeedValidation(result))) {
                throw Exception(
                    "Validation has been requested but wasn't handled");
              }
            } catch (e) {
              onRequestStateChange(
                VKGetTrace(
                  state: VKGetTraceRequestState.cancelled,
                  type: r.isOauth
                      ? VKGetTraceRequestType.oauth
                      : VKGetTraceRequestType.api,
                  target: r.method,
                  payload: r.data,
                  statePayload: e,
                ),
              );
              rethrow;
            }
            queueLock = true;
            continue;
          }
        }

        if (json is Map<String, dynamic> &&
            json.containsKey(errorDetectionKey)) {
          onRequestStateChange(
            VKGetTrace(
              state: VKGetTraceRequestState.error,
              type: r.isOauth
                  ? VKGetTraceRequestType.oauth
                  : VKGetTraceRequestType.api,
              target: r.method,
              payload: r.data,
              statePayload: json,
            ),
          );
          r.completer.completeError(json);
        } else {
          onRequestStateChange(
            VKGetTrace(
              state: VKGetTraceRequestState.done,
              type: r.isOauth
                  ? VKGetTraceRequestType.oauth
                  : VKGetTraceRequestType.api,
              target: r.method,
              payload: r.data,
              response: result,
            ),
          );
          r.completer.complete(result);
        }

        if (failedProxies.length == proxies.length) {
          try {
            if (await VKGetUtils.checkPureInternetConnection()) {
              failedProxies.clear();
            } else {
              onRequestStateChange(
                VKGetTrace(
                  state: VKGetTraceRequestState.delayed,
                  type: r.isOauth
                      ? VKGetTraceRequestType.oauth
                      : VKGetTraceRequestType.api,
                  target: r.method,
                  payload: r.data,
                  statePayload: 'Access Problems',
                ),
              );

              if (await onAccessProblems()) {
                queueLock = true;
                continue;
              }
            }
          } catch (e) {
            onRequestStateChange(
              VKGetTrace(
                state: VKGetTraceRequestState.delayed,
                type: r.isOauth
                    ? VKGetTraceRequestType.oauth
                    : VKGetTraceRequestType.api,
                target: r.method,
                payload: r.data,
                statePayload: 'No Internet',
              ),
            );

            // Internet is shit
            failedProxies.clear();
            try {
              if (await onConnectionProblems()) {
                queueLock = true;
                continue;
              }
            } catch (e) {
              onRequestStateChange(
                VKGetTrace(
                  state: VKGetTraceRequestState.cancelled,
                  type: r.isOauth
                      ? VKGetTraceRequestType.oauth
                      : VKGetTraceRequestType.api,
                  target: r.method,
                  payload: r.data,
                  statePayload: e,
                ),
              );
              rethrow;
            }
          }
        }

        failedProxies.forEach((element) {
          proxies.remove(element);
        });
      } while (queueLock);
    } catch (e) {
      onRequestStateChange(
        VKGetTrace(
          state: VKGetTraceRequestState.cancelled,
          type: r.isOauth
              ? VKGetTraceRequestType.oauth
              : VKGetTraceRequestType.api,
          target: r.method,
          payload: r.data,
          statePayload: e,
        ),
      );
      r.completer.completeError(e);
      rethrow;
    }
  }
}

enum VKGetTraceRequestState { queued, active, done, error, cancelled, delayed }
enum VKGetTraceRequestType { api, oauth, fetch }

class VKGetTrace {
  final VKGetTraceRequestState state;
  final VKGetTraceRequestType type;
  final VKGetRequest? request;
  final VKGetResponse? response;
  final Object? statePayload;
  final String target;
  final Object payload;

  @override
  String toString() {
    var s = '[VKGet Trace]';

    s += ' ';
    switch (type) {
      case VKGetTraceRequestType.api:
        s += '[API]';
        break;
      case VKGetTraceRequestType.oauth:
        s += '[OAUTH]';
        break;
      case VKGetTraceRequestType.fetch:
        s += '[FETCH]';
        break;
    }

    s += ' [${request.hashCode}]';

    s += ': ';
    switch (state) {
      case VKGetTraceRequestState.queued:
        s += 'QUEUED';
        break;
      case VKGetTraceRequestState.active:
        s += 'ACTIVE';
        break;
      case VKGetTraceRequestState.done:
        s += 'DONE';
        break;
      case VKGetTraceRequestState.error:
        s += 'ERROR';
        break;
      case VKGetTraceRequestState.cancelled:
        s += 'CANCELLED';
        break;
      case VKGetTraceRequestState.delayed:
        s += 'DELAYED';
        break;
    }

    s += '\n';
    s += '- $target\n- ${jsonEncode(payload)}';

    if (statePayload != null) {
      s += '\n$statePayload';
    }

    var r = response;
    if (r != null) {
      try {
        s += jsonEncode(r.asJson);
      } catch (e) {
        s += r.body;
      }
    }

    return s;
  }

  VKGetTrace({
    required this.state,
    required this.type,
    this.request,
    this.response,
    required this.target,
    required this.payload,
    this.statePayload,
  });
}

class _QueueElement {
  _QueueElement(this.time, {this.isBusy = false});
  final DateTime time;
  bool isBusy;
}
