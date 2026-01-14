flutter pub run flutter_launcher_icons; flutter build windows
Compress-Archive -Path "build/windows/x64/runner/Release/" -DestinationPath "auto_wifi_win.zip"
curl --http1.1 -X POST -H "Authorization: Bearer $env:API_TOKEN" -F "file=@auto_wifi_win.zip" https://update.aextoxicon.site/upload
