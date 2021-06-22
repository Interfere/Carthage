#!/usr/bin/xcrun make -f

UTICA_TEMPORARY_FOLDER?=/tmp/Utica.dst
PREFIX?=/usr/local

INTERNAL_PACKAGE=UticaApp.pkg
OUTPUT_PACKAGE=Utica.pkg

UTICA_EXECUTABLE=./.build/release/utica
BINARIES_FOLDER=$(PREFIX)/bin

SWIFT_BUILD_FLAGS=--configuration release -Xswiftc -suppress-warnings

SWIFTPM_DISABLE_SANDBOX_SHOULD_BE_FLAGGED:=$(shell test -n "$${HOMEBREW_SDKROOT}" && echo should_be_flagged)
ifeq ($(SWIFTPM_DISABLE_SANDBOX_SHOULD_BE_FLAGGED), should_be_flagged)
SWIFT_BUILD_FLAGS+= --disable-sandbox
endif
SWIFT_STATIC_STDLIB_SHOULD_BE_FLAGGED:=$(shell test -d $$(dirname $$(xcrun --find swift))/../lib/swift_static/macosx && echo should_be_flagged)
ifeq ($(SWIFT_STATIC_STDLIB_SHOULD_BE_FLAGGED), should_be_flagged)
SWIFT_BUILD_FLAGS+= -Xswiftc -static-stdlib
endif

# ZSH_COMMAND · run single command in `zsh` shell, ignoring most `zsh` startup files.
ZSH_COMMAND := ZDOTDIR='/var/empty' zsh -o NO_GLOBAL_RCS -c
# RM_SAFELY · `rm -rf` ensuring first and only parameter is non-null, contains more than whitespace, non-root if resolving absolutely.
RM_SAFELY := $(ZSH_COMMAND) '[[ ! $${1:?} =~ "^[[:space:]]+\$$" ]] && [[ $${1:A} != "/" ]] && [[ $${\#} == "1" ]] && noglob rm -rf $${1:A}' --

VERSION_STRING=$(shell git describe --abbrev=0 --tags)
DISTRIBUTION_PLIST=Source/utica/Distribution.plist

RM=rm -f
MKDIR=mkdir -p
SUDO=sudo
CP=cp

ifdef DISABLE_SUDO
override SUDO:=
endif

.PHONY: all clean install package test uninstall xcconfig xcodeproj

all: installables

clean:
	swift package clean

test:
	$(RM_SAFELY) ./.build/debug/UticaPackageTests.xctest
	swift build --build-tests -Xswiftc -suppress-warnings
	$(CP) -R Tests/UticaKitTests/Resources ./.build/debug/UticaPackageTests.xctest/Contents
	$(CP) Tests/UticaKitTests/fixtures/CartfilePrivateOnly.zip ./.build/debug/UticaPackageTests.xctest/Contents/Resources
	script/copy-fixtures ./.build/debug/UticaPackageTests.xctest/Contents/Resources
	swift test --skip-build

installables:
	swift build $(SWIFT_BUILD_FLAGS)

package: installables
	$(MKDIR) "$(UTICA_TEMPORARY_FOLDER)$(BINARIES_FOLDER)"
	$(CP) "$(UTICA_EXECUTABLE)" "$(UTICA_TEMPORARY_FOLDER)$(BINARIES_FOLDER)"
	
	pkgbuild \
		--identifier "org.utica.utica" \
		--install-location "/" \
		--root "$(UTICA_TEMPORARY_FOLDER)" \
		--version "$(VERSION_STRING)" \
		"$(INTERNAL_PACKAGE)"

	productbuild \
	  	--distribution "$(DISTRIBUTION_PLIST)" \
	  	--package-path "$(INTERNAL_PACKAGE)" \
	   	"$(OUTPUT_PACKAGE)"

prefix_install: installables
	$(MKDIR) "$(BINARIES_FOLDER)"
	$(CP) -f "$(UTICA_EXECUTABLE)" "$(BINARIES_FOLDER)/"

install: installables
	if [ ! -d "$(BINARIES_FOLDER)" ]; then $(SUDO) $(MKDIR) "$(BINARIES_FOLDER)"; fi
	$(SUDO) $(CP) -f "$(UTICA_EXECUTABLE)" "$(BINARIES_FOLDER)"

uninstall:
	$(RM) "$(BINARIES_FOLDER)/utica"
	
xcodeproj:
	 swift package generate-xcodeproj
