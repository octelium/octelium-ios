.PHONY: release release-major release-minor release-patch sync-proto generate-proto build-liboctelium \
	build-host-libs project test test-host test-ios build check-generated

SIMULATOR ?= platform=iOS Simulator,name=iPhone 17

release:
	@./scripts/release.sh "$(VERSION)"

release-major:
	@./scripts/release.sh major

release-minor:
	@./scripts/release.sh minor

release-patch:
	@./scripts/release.sh patch

sync-proto:
	./scripts/sync-proto.sh

generate-proto:
	./scripts/generate-proto.sh

check-generated: generate-proto
	git diff --exit-code -- OcteliumKit/Sources/OcteliumProto/Generated OcteliumKit/Sources/OcteliumAPI/Generated

build-liboctelium:
	./scripts/build-liboctelium.sh

build-host-libs:
	./scripts/build-host-libs.sh

project:
	./scripts/generate-project.sh

test:
	swift test --package-path OcteliumKit

test-host: build-host-libs
	swift test --package-path HostTests

test-ios: project
	xcodebuild test -project Octelium.xcodeproj -scheme Octelium -destination '$(SIMULATOR)' CODE_SIGNING_ALLOWED=NO

build: project
	xcodebuild build -project Octelium.xcodeproj -scheme Octelium -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO
