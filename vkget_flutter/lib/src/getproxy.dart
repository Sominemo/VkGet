import 'package:device_info_plus/device_info_plus.dart';
import 'package:vkget/vkget.dart';

class VKGetUtilsFlutter extends VKGetUtils {
  static Future<VKProxyList> getProxyListAsAndroidDevice() async {
    DeviceInfoPlugin deviceInfo = DeviceInfoPlugin();
    AndroidDeviceInfo androidInfo = await deviceInfo.androidInfo;

    try {
      return await VKGetUtils.getProxyList(
        sdk: androidInfo.version.sdkInt,
        version: androidInfo.version.release,
        device: androidInfo.model,
      );
    } catch (e) {
      return VKProxyList({}, {});
    }
  }
}
