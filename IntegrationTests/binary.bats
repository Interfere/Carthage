#!/usr/bin/env bats

setup() {
    cd $BATS_TMPDIR
    rm -rf BinaryTest
    mkdir BinaryTest && cd BinaryTest
    echo 'binary "https://dl.google.com/dl/firebase/ios/carthage/FirebaseAnalyticsBinary.json"' > Cartfile
}

teardown() {
    cd $BATS_TEST_DIRNAME
}

@test "utica update builds everything (binary)" {
    run utica update --platform iOS --valid-simulator-archs "i386 x86_64"

    [ "$status" -eq 0 ]
    [ -d Carthage/Build/FirebaseAnalytics.xcframework ]
}
