flutter pub run flutter_launcher_icons && flutter build apk --release && flutter build macos #&& adb install build/app/outputs/flutter-apk/app-release.apk
cp build/app/outputs/flutter-apk/app-release.apk auto_wifi_android.apk
zip -r -X auto_wifi_mac.zip build/macos/Build/Products/Release/auto_wifi.app
curl --http1.1 -X POST -H "Authorization: Bearer $API_TOKEN" -F "file=@auto_wifi_mac.zip" https://update.aextoxicon.site/upload
curl --http1.1 -X POST -H "Authorization: Bearer $API_TOKEN" -F "file=@auto_wifi_android.apk" https://update.aextoxicon.site/upload