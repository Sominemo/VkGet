import 'dart:async';
import 'dart:io';

import 'package:vkget/vkget.dart';

class VKGetTokenData {
  VKGetTokenData(this.token, this.userId, this.expireDate);

  final String token;
  final int userId;
  final DateTime expireDate;

  @override
  String toString() => '[TOKEN $token for ID$userId, expires $expireDate]';
}

Future<void> main() async {
  print(await getTokenInteractive());
}

Future<void> initConnection(VKGet vk) async {
  Duration? ping;

  try {
    ping = await VKGetUtils.pingVK(vk.client, timeout: Duration(seconds: 1));
  } catch (e) {
    final r = await VKGetUtils.getProxyList();

    VKGetUtils.trustify(r.certificates, vk.client);
    vk.proxies = r.proxy;
    Object? lastError;
    for (final proxy in r.proxy) {
      try {
        ping = await VKGetUtils.pingVK(vk.client,
            proxy: proxy, timeout: Duration(seconds: 1));
        break;
      } catch (e) {
        lastError = e;
      }
    }
    if (ping == null) {
      print("Couldn't find a working proxy");
      if (lastError != null) throw lastError;
      exit(1);
    }
  }
}

Future<VKGetTokenData> getTokenInteractive({String version = '5.130'}) async {
  stdout.writeln('VKGet CLI - Get Token\n');

  final vk = VKGet(
    version,
    '',
    onCaptcha: (r) async {
      stdout.writeln(
          '[?] VK asks you to enter captcha: ${r.asJson()['captcha_img']}');
      final input = stdin.readLineSync();
      if (input == null) throw TypeError();
      return (input);
    },
    specialValidationHandling: false,
  );

  stdout.writeln('[*] Connecting to VK...');
  Duration? ping;

  try {
    ping = await VKGetUtils.pingVK(vk.client, timeout: Duration(seconds: 1));
  } catch (e) {
    stdout.writeln('[*] Failed to connect to VK. Fetching proxies...');

    final r = await VKGetUtils.getProxyList();

    VKGetUtils.trustify(r.certificates, vk.client);
    vk.proxies = r.proxy;
    stdout.writeln('[*] Testing proxies...');
    Object? lastError;
    var connectionTries = 1;
    for (final proxy in r.proxy) {
      try {
        ping = await VKGetUtils.pingVK(vk.client,
            proxy: proxy, timeout: Duration(seconds: 1));
        break;
      } catch (e) {
        connectionTries++;
        lastError = e;
      }
    }
    if (ping == null) {
      stdout
          .writeln('[!] Failed to connect to VK. Tries made: $connectionTries');
      if (lastError != null) throw lastError;
      exit(1);
    }
    if (connectionTries > 0) {
      stdout.writeln('[*] Found proxy. Tries made: $connectionTries');
    }
  }

  stdout.writeln('[*] Connected to VK in $ping\n\n');

  stdout.writeln('Username:');
  final username = stdin.readLineSync();

  stdout.writeln('Password:');
  stdin.echoMode = false;
  final password = stdin.readLineSync();
  stdin.echoMode = true;
  stdout.writeln('<password entered>\n');

  if (username == null || password == null) throw TypeError();

  return await loginFlow(
    vk,
    username,
    password,
    '2274003',
    'hHbZxrka2uZ6jB1inYsH',
  );
}

Future<VKGetTokenData> loginFlow(
    VKGet vk, String username, String password, String clientId, String secret,
    {String? code}) async {
  final requestBody = {
    'grant_type': 'password',
    'client_id': clientId,
    'client_secret': secret,
    'username': username,
    'password': password,
    '2fa_supported': '1',
    if (code != null) 'code': code
  };

  try {
    final oauth = await vk.call('token', requestBody, oauth: true);

    final Map<String, dynamic> oauthRes =
        oauth.asJson() as Map<String, dynamic>;

    final String accessToken = oauthRes['access_token'] as String;
    if (oauthRes['access_token'] == null) throw TypeError();

    return VKGetTokenData(
      accessToken,
      oauthRes['user_id'] as int? ?? 0,
      DateTime.fromMillisecondsSinceEpoch(
          oauthRes['expires_in'] as int? ?? 0 * 100),
    );
  } catch (e) {
    if (e is! Map<String, dynamic> || e['error'] != 'need_validation') rethrow;

    var twofaValidate = false;

    if (e['validation_type'] == '2fa_app') {
      twofaValidate = true;
      print('[?] VK sent you a 2FA code in app');
    } else if (e['validation_type'] == '2fa_sms') {
      twofaValidate = true;
      print('[?] VK sent you a 2FA code in SMS on ${e['phone_mask']}');
    }

    if (!twofaValidate) {
      print(
          '[?] VK asks you to confirm your account in browser: ${e['redirect_uri']}\nAfter submitting, copy the URL and paste it here:');
      final input = stdin.readLineSync();
      if (input == null) throw TypeError();
      String userToken;
      try {
        final parsedLink = Uri.parse(input);
        final accessTokenParam =
            Uri.splitQueryString(parsedLink.fragment)['access_token'];
        if (accessTokenParam == null) {
          throw Exception('Invalid access token');
        } else {
          userToken = accessTokenParam;
        }
      } on FormatException {
        userToken = input;
      }

      vk.token = userToken;
      final dynamic checkTokenCall =
          (await vk.call('users.get', <String, String>{})).asJson();
      vk.token = '';

      if (checkTokenCall is! Map<String, dynamic>) throw TypeError();
      final resCall = checkTokenCall;

      return VKGetTokenData(
        userToken,
        resCall['response'][0]['id'] as int? ?? 0,
        DateTime.fromMillisecondsSinceEpoch(0),
      );
    }

    print("Type 'sms' to receive the code in SMS or 'voice' to get a call");

    String? input;
    do {
      input = stdin.readLineSync();

      if (input == null) throw TypeError();
      if (input == 'sms' || input == 'voice') {
        DateTime? delay;
        try {
          delay = DateTime.now().add(
            Duration(
              seconds: (await vk.call(
                'auth.validatePhone',
                <String, String>{
                  'sid': e['validation_sid'] as String,
                  if (input == 'voice') 'voice': '1',
                },
              ))
                  .asJson()['delay'] as int,
            ),
          );
          print('[?] VK sent you a 2FA code in SMS on ${e['phone_mask']}');
        } catch (e) {
          if (e is Map<String, dynamic> &&
              (e['error']['error_code'] == 1112 ||
                  e['error']['error_code'] == 103)) {
            print(
              '[!] Wait until you can send the code again: ${(delay == null ? 'You request codes too often' : DateTime.now().difference(delay))}',
            );
          } else {
            rethrow;
          }
        }

        input = null;
      }
    } while (input == null);
    return await loginFlow(
      vk,
      username,
      password,
      clientId,
      secret,
      code: input,
    );
  }
}
