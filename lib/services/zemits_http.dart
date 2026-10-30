import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';

/// Device Service için HTTP istemcisi.
///
/// devices.zemits.ai sertifika zinciri ISRG Root X2'de biter (YE1 ← Root YE ← X2). X2,
/// Android 14'ten eski cihazların güven deposunda olmayabilir (ör. Android 11 telefon);
/// bu yüzden sistem köklerine ek olarak X2 de güvenilir sayılır. Ad doğrulaması değişmez.
/// Kaynak: https://letsencrypt.org/certs/isrg-root-x2.pem
/// SHA-256: 69:72:9B:8E:15:A8:6E:FC:17:7A:57:AF:B7:17:1D:FC:64:AD:D2:8C:2F:CA:8C:F1:50:7E:34:45:3C:CB:14:70
http.Client zemitsHttpClient() {
  final ctx = SecurityContext(withTrustedRoots: true);
  try {
    ctx.setTrustedCertificatesBytes(utf8.encode(_isrgRootX2));
  } catch (_) {
    // sistem deposunda zaten varsa eklemek hata verebilir; sorun değil
  }
  return IOClient(HttpClient(context: ctx)..connectionTimeout = const Duration(seconds: 20));
}

const _isrgRootX2 = '''
-----BEGIN CERTIFICATE-----
MIICGzCCAaGgAwIBAgIQQdKd0XLq7qeAwSxs6S+HUjAKBggqhkjOPQQDAzBPMQsw
CQYDVQQGEwJVUzEpMCcGA1UEChMgSW50ZXJuZXQgU2VjdXJpdHkgUmVzZWFyY2gg
R3JvdXAxFTATBgNVBAMTDElTUkcgUm9vdCBYMjAeFw0yMDA5MDQwMDAwMDBaFw00
MDA5MTcxNjAwMDBaME8xCzAJBgNVBAYTAlVTMSkwJwYDVQQKEyBJbnRlcm5ldCBT
ZWN1cml0eSBSZXNlYXJjaCBHcm91cDEVMBMGA1UEAxMMSVNSRyBSb290IFgyMHYw
EAYHKoZIzj0CAQYFK4EEACIDYgAEzZvVn4CDCuwJSvMWSj5cz3es3mcFDR0HttwW
+1qLFNvicWDEukWVEYmO6gbf9yoWHKS5xcUy4APgHoIYOIvXRdgKam7mAHf7AlF9
ItgKbppbd9/w+kHsOdx1ymgHDB/qo0IwQDAOBgNVHQ8BAf8EBAMCAQYwDwYDVR0T
AQH/BAUwAwEB/zAdBgNVHQ4EFgQUfEKWrt5LSDv6kviejM9ti6lyN5UwCgYIKoZI
zj0EAwMDaAAwZQIwe3lORlCEwkSHRhtFcP9Ymd70/aTSVaYgLXTWNLxBo1BfASdW
tL4ndQavEi51mI38AjEAi/V3bNTIZargCyzuFJ0nN6T5U6VR5CmD1/iQMVtCnwr1
/q4AaOeMSQ+2b1tbFfLn
-----END CERTIFICATE-----
''';
