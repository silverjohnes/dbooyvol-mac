SHELL := /bin/sh
APP := build/Build/Products/Debug/DBooyvol.app
BUILD_FILE := build-number.txt

.PHONY: all sidecar localize project bump-build build run release clean

all: build

sidecar:
	@if [ ! -f Resources/sidecar.jar ] || [ -n "$$(find Sidecar/src -name '*.java' -newer Resources/sidecar.jar -print -quit)" ]; then \
		./Sidecar/build.sh; \
	else \
		echo "→ sidecar.jar актуален"; \
	fi

localize:
	python3 Scripts/localize.py

project: sidecar
	@if [ ! -f DBooyvol.xcodeproj/project.pbxproj ] || [ project.yml -nt DBooyvol.xcodeproj/project.pbxproj ]; then \
		echo "→ xcodegen generate"; \
		xcodegen generate; \
	else \
		echo "→ project.yml не менялся, проект не перегенерирую"; \
	fi

# Each build gets a new number, shown in the About panel and Info.plist.
bump-build:
	@n=$$(cat $(BUILD_FILE) 2>/dev/null || echo 0); n=$$((n+1)); echo $$n > $(BUILD_FILE); \
	sed -i '' -E "s/(CURRENT_PROJECT_VERSION: \")[0-9]+(\")/\1$$n\2/" project.yml; \
	sed -i '' -E "s/(CFBundleVersion: \")[0-9]+(\")/\1$$n\2/" project.yml; \
	echo "→ сборка $$n"

build: bump-build project
	xcodebuild -project DBooyvol.xcodeproj -scheme DBooyvol -configuration Debug \
		-derivedDataPath build -allowProvisioningUpdates build

run: build
	open "$(APP)"

release: bump-build project
	xcodebuild -project DBooyvol.xcodeproj -scheme DBooyvol -configuration Release \
		-derivedDataPath build -allowProvisioningUpdates build

clean:
	rm -rf build DBooyvol.xcodeproj Resources/sidecar.jar Sidecar/build
