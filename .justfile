build:
    xcodebuild -scheme Dawn -configuration Release build -derivedDataPath ./build

run:
    open ./build/Build/Products/Release/Dawn.app
