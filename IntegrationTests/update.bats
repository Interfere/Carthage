#!/usr/bin/env bats

setup() {
    cd $BATS_TMPDIR
    rm -rf UpdateTest
    mkdir UpdateTest && cd UpdateTest
    echo 'github "antitypical/Result" == 5.0.0' > Cartfile
    echo 'github "Quick/Nimble" == 10.0.0' > Cartfile.private
}

teardown() {
    cd $BATS_TEST_DIRNAME
}

@test "utica update builds everything" {
    run utica update --platform mac --no-use-binaries
    [ "$status" -eq 0 ]
    [ -e Carthage/Build/Mac/Result.framework ]
    [ -e Carthage/Build/Mac/Nimble.framework ]
}
