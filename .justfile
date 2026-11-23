build:
    xcodebuild -scheme Dawn -configuration Release build -derivedDataPath ./build

run:
    open ./build/Build/Products/Release/Dawn.app

deploy: build
    #!/bin/sh
    set -e
    app=/Applications/Dawn.app
    running=$(pgrep -f "^$app/Contents/MacOS/Dawn$" || true)
    if [ -n "$running" ]; then
        osascript -e 'tell application id "com.csutora.Dawn" to quit'
        while kill -0 $running 2>/dev/null; do sleep 0.1; done
    fi
    rm -rf $app
    ditto ./build/Build/Products/Release/Dawn.app $app
    [ "$(readlink /usr/local/bin/dawn)" = $app/Contents/Resources/dawn ] || sudo sh -c "mkdir -p /usr/local/bin && ln -sf $app/Contents/Resources/dawn /usr/local/bin/dawn"
    if [ -n "$running" ]; then open $app; fi

test:
    xcodebuild -scheme Dawn -configuration Debug build -derivedDataPath ./build-debug
    ./build-debug/Build/Products/Debug/Dawn.app/Contents/MacOS/Dawn
