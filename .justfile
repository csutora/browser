build:
    xcodebuild -scheme Dawn -configuration Release build -derivedDataPath ./build

run:
    open ./build/Build/Products/Release/Dawn.app

test:
    xcodebuild -scheme Dawn -configuration Debug build -derivedDataPath ./build-debug
    ./build-debug/Build/Products/Debug/Dawn.app/Contents/MacOS/Dawn
