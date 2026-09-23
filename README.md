# BMray

Исходный код мобильного клиента подписок на базе Flutter и sing-box (libbox).
Пользователь вставляет **HTTPS-ссылку подписки из своего VPN бота**, выбирает
сервер и подключается через системный VPN. Домен `bolvankamax.com` использован
для идентификатора приложения `com.bolvankamax.bmray`; серверы и подписки
принадлежат пользователям, домен не обслуживает VPN трафик.

## Возможности и форматы

- Android: `VpnService` + sing-box; iOS: `PacketTunnelProvider` + sing-box.
- Импорт и обновление HTTPS подписок, выбор подписки и узла, подключение/отключение.
- Ссылки и узлы хранятся в защищённом хранилище устройства.
- Поддерживаются sing-box JSON с `outbounds`, текстовый список ссылок и
  base64 с ссылками `vless://`, `vmess://`, `trojan://`, `ss://`,
  `hysteria2://`, `hy2://`, `tuic://`.
- Clash YAML: распространённые узлы VLESS, VMess, Trojan, Shadowsocks,
  Hysteria2 и TUIC, включая обычные WebSocket/gRPC и Reality. Уникальные
  расширения Mihomo/Clash и проприетарные форматы ботов пока не поддерживаются.
  Если конкретная подписка не распознана, в боте попробуйте формат sing-box.

## Сборка Android кнопкой на GitHub

Откройте **Actions → Android APK and AAB → Run workflow → Run workflow**.
После успешного завершения откройте запуск и скачайте архив
`BMray-android-test-<номер>` в разделе **Artifacts**. Для скачивания нужно
войти в GitHub. Архив содержит APK для установки и AAB для проверки сборки.
Файлы хранятся 14 дней; повторный запуск создаёт новые.

Эти пакеты подписаны временным **тестовым** ключом и не предназначены для
Google Play. При установке следующей тестовой сборки может потребоваться
сначала удалить предыдущую (при этом удалятся сохранённые подписки).
Для публикации используйте постоянный собственный keystore, как описано ниже.
Тестовые APK и AAB также можно собрать локально:

```sh
bash scripts/build_android_test.sh
```

## Сборка Android для публикации (APK и AAB)

Нужны Flutter SDK 3.47+, Android SDK (API 36), JDK 17 и интернет на этапе
первой сборки. В `packages/vpn_plugin` включён исходный код нативного моста;
бинарный `libbox.aar` автоматически скачивается при сборке из закреплённого
релиза и проверяется по SHA-256. Первый `flutter pub get` получает зависимости.

Для подписанной сборки создайте **свой** keystore и храните его вне проекта:

```sh
keytool -genkeypair -v -keystore /secure/path/bmray-upload.jks \
  -alias bmray -keyalg RSA -keysize 3072 -validity 10000
export BMRAY_KEYSTORE_FILE=/secure/path/bmray-upload.jks
export BMRAY_KEY_ALIAS=bmray
export BMRAY_KEYSTORE_PASSWORD='пароль-хранилища'
export BMRAY_KEY_PASSWORD='пароль-ключа'
bash scripts/build_android.sh
```

Полученные файлы: `build/app/outputs/flutter-apk/app-release.apk` и
`build/app/outputs/bundle/release/app-release.aab`. Сохраните keystore и пароли:
без них нельзя выпускать обновления приложения с прежней подписью.

## Сборка iOS (IPA)

Нужны Mac с Xcode, Flutter SDK 3.47+, CocoaPods и Apple Developer team с
возможностью подписать **оба** target: Runner и SingboxTunnel. Скрипт создаёт
расширение Packet Tunnel и его entitlements; Xcode/Apple должны разрешить
`Network Extensions` и `App Groups` для `com.bolvankamax.bmray` и
`com.bolvankamax.bmray.SingboxTunnel`. Перед сборкой задайте `DEV_TEAM` как
идентификатор своей Apple Developer team:

```sh
export DEV_TEAM=ВАШ_TEAM_ID
bash scripts/build_ios.sh
```

Скрипт получает `Libbox.xcframework.zip` из закреплённого релиза с проверкой
SHA-256 и создаёт `build/ios/ipa/*.ipa`. Первую сборку нужно проверить в Xcode
на физическом iPhone. Разрешение системного VPN запрашивается при первом
подключении. Профили подписи и сертификаты остаются под контролем владельца
Apple Developer аккаунта.

## Устройство проекта

- `lib/` — интерфейс, импорт и хранение подписок;
- `packages/vpn_plugin/` — исходники нативного моста (GPL-3.0), с исправлениями
  для имени пакета, бренда, проверки бинарников и выбора своего VPN профиля;
- `android/`, `ios/` — конфигурации платформ;
- `scripts/` — сборка релизных пакетов.

Код BMray и включённого плагина распространяется на условиях GPL-3.0; при
распространении приложения предоставляйте исходный код вместе с условиями
лицензии. Исходный код самого sing-box: https://github.com/SagerNet/sing-box.

## Статус проверки

Исходники парсера и генератора конфигурации проверены локальным smoke тестом
на base64/VLESS и Clash YAML. Конфигурации для шести распространённых типов
узлов Clash успешно прошли `sing-box check` в официальном бинарном выпуске
1.13.13. Сборка Flutter, запуск на Android и сборка iOS **не проверены**
в текущем окружении. До публикации необходимо собрать оба пакета, подключиться
на реальных устройствах с собственной подпиской и проверить трафик/DNS.
