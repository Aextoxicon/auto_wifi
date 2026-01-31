flutter pub run flutter_launcher_icons && flutter build apk --release && flutter build macos #&& adb install build/app/outputs/flutter-apk/app-release.apk
cp build/app/outputs/flutter-apk/app-release.apk eureka_android.apk
zip -r -X eureka_mac.zip build/macos/Build/Products/Release/eureka.app
curl --http1.1 -X POST -H "Authorization: Bearer $API_TOKEN" -F "file=@eureka_mac.zip" https://update.aextoxicon.site/upload
curl --http1.1 -X POST -H "Authorization: Bearer $API_TOKEN" -F "file=@eureka_android.apk" https://update.aextoxicon.site/upload