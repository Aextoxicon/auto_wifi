echo "build started"
$env:GOOS="linux"; $env:GOARCH="amd64"; go build -o bin/auto-wifi-linux-amd64 main.go
echo "linux-amd64 build complete"
$env:GOOS="windows"; $env:GOARCH="amd64"; go build -o bin/auto-wifi-windows-amd64.exe main.go
echo "windows-amd64 build complete"
$env:GOOS="darwin"; $env:GOARCH="amd64"; go build -o bin/auto-wifi-macos-amd64 main.go
echo "macos-amd64 build complete"
$env:GOOS="linux"; $env:GOARCH="arm64"; go build -o bin/auto-wifi-linux-arm64 main.go
echo "linux-arm64 build complete"
$env:GOOS="darwin"; $env:GOARCH="arm64"; go build -o bin/auto-wifi-macos-arm64 main.go
echo "macos-arm64 build complete"