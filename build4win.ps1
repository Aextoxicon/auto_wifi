flutter pub run flutter_launcher_icons; flutter build windows
Compress-Archive -Path "build/windows/x64/runner/Release/" -DestinationPath "eureka_win.zip"
curl --http1.1 -X POST -H "Authorization: Bearer $env:API_TOKEN" -F "file=@eureka_win.zip" http://update.aextoxicon.site/upload
