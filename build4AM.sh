flutter pub run flutter_launcher_icons && flutter build apk --release && flutter build macos #&& adb install build/app/outputs/flutter-apk/app-release.apk
cp build/app/outputs/flutter-apk/app-release.apk ~/Desktop/base.apk
cp -r build/macos/Build/Products/Release/auto_wifi.app ~/Desktop/