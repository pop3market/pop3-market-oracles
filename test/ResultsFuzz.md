Compiler run successful!

Ran 8 tests for test/fuzz/UmaOracleAdapterFuzz.t.sol:UmaOracleAdapterFuzzTest
[PASS] testFuzz_admin_nonOwnerReverts(address) (runs: 10000, μ: 25233, ~: 25233)
[PASS] testFuzz_initializeQuestion_delayTooLong(uint64) (runs: 10000, μ: 107340, ~: 107263)
[PASS] testFuzz_initializeQuestion_duplicateReverts(bytes32) (runs: 10000, μ: 376798, ~: 376798)
[PASS] testFuzz_initializeQuestion_livenessTooShort(uint64) (runs: 10000, μ: 107121, ~: 107180)
[PASS] testFuzz_initializeQuestion_nonAuthorizedReverts(address) (runs: 10000, μ: 22924, ~: 22925)
[PASS] testFuzz_operatorDelay_blocksPublic(uint64,uint64) (runs: 10000, μ: 373660, ~: 373594)
[PASS] testFuzz_setDefaultBond_success(uint256) (runs: 10000, μ: 18588, ~: 18604)
[PASS] testFuzz_settleQuestion_outcomeMatchesTruthfulness(bool) (runs: 10000, μ: 357910, ~: 367821)
Suite result: ok. 8 passed; 0 failed; 0 skipped; finished in 4.58s (22.46s CPU time)

Ran 6 tests for test/fuzz/LzCrossChainRelayFuzz.t.sol:LzCrossChainReceiverFuzzTest
[PASS] testFuzz_admin_nonOwnerReverts(address) (runs: 10000, μ: 16121, ~: 16122)
[PASS] testFuzz_allowInitializePath(uint32,bytes32) (runs: 10000, μ: 8346, ~: 8344)
[PASS] testFuzz_lzReceive_nonEndpointReverts(address) (runs: 10000, μ: 18083, ~: 18084)
[PASS] testFuzz_lzReceive_revertsOnAnyETH(uint256) (runs: 10000, μ: 24963, ~: 24883)
[PASS] testFuzz_lzReceive_routingByRequestId(bytes32,bytes32,bool) (runs: 10000, μ: 111029, ~: 101233)
[PASS] testFuzz_lzReceive_untrustedSenderReverts(bytes32) (runs: 10000, μ: 20561, ~: 20561)
Suite result: ok. 6 passed; 0 failed; 0 skipped; finished in 7.21s (9.37s CPU time)

Ran 4 tests for test/fuzz/LzCrossChainRelayFuzz.t.sol:LzCrossChainSenderFuzzTest
[PASS] testFuzz_addAdapter_success(address) (runs: 10000, μ: 36849, ~: 36849)
[PASS] testFuzz_admin_nonOwnerReverts(address) (runs: 10000, μ: 24679, ~: 24680)
[PASS] testFuzz_sendAnswer_nonAdapterReverts(address) (runs: 10000, μ: 19417, ~: 19417)
[PASS] testFuzz_sendAnswer_payloadEncoding(bytes32,bytes32,bool) (runs: 10000, μ: 261765, ~: 251979)
Suite result: ok. 4 passed; 0 failed; 0 skipped; finished in 7.21s (8.32s CPU time)

Ran 13 tests for test/fuzz/ChainlinkPriceResolverFuzz.t.sol:ChainlinkPriceResolverFuzzTest
[PASS] testFuzz_admin_nonOwnerReverts(address) (runs: 10000, μ: 35956, ~: 35957)
[PASS] testFuzz_constructor_rejectsZeroAddresses(address,address,address) (runs: 10000, μ: 2085668, ~: 2086884)
[PASS] testFuzz_createAboveThreshold_invalidThreshold(int256) (runs: 10000, μ: 18940, ~: 18739)
[PASS] testFuzz_createInRange_invalidRange(int256,int256) (runs: 10000, μ: 20482, ~: 20553)
[PASS] testFuzz_createInRange_negativeLowerBound(int256) (runs: 10000, μ: 19607, ~: 19409)
[PASS] testFuzz_createUpDown_invalidTimeRange(uint64,uint64) (runs: 10000, μ: 20831, ~: 20831)
[PASS] testFuzz_create_delayTooLong(uint64) (runs: 10000, μ: 21496, ~: 21442)
[PASS] testFuzz_create_nonAuthorizedReverts(address) (runs: 10000, μ: 19469, ~: 19469)
[PASS] testFuzz_setMaxStaleness_success(uint256) (runs: 10000, μ: 18654, ~: 18678)
[PASS] testFuzz_settleAboveThreshold_outcomeProperty(int256,int256) (runs: 10000, μ: 353290, ~: 361605)
[PASS] testFuzz_settleInRange_outcomeProperty(int256,int256,int256) (runs: 10000, μ: 368659, ~: 364059)
[PASS] testFuzz_settleUpDown_outcomeProperty(int256,int256) (runs: 10000, μ: 454848, ~: 463087)
[PASS] testFuzz_settle_operatorDelayBlocksPublic(uint64,uint64) (runs: 10000, μ: 281825, ~: 281969)
Suite result: ok. 13 passed; 0 failed; 0 skipped; finished in 7.21s (32.31s CPU time)

Ran 13 tests for test/fuzz/BridgeReceiverFuzz.t.sol:BridgeReceiverFuzzTest
[PASS] testFuzz_acceptOwnership_onlyProposedCanAccept(address,address) (runs: 10000, μ: 37648, ~: 37648)
[PASS] testFuzz_addRelayer_nonOwnerReverts(address,address) (runs: 10000, μ: 12098, ~: 12099)
[PASS] testFuzz_addRelayer_success(address) (runs: 10000, μ: 37442, ~: 37442)
[PASS] testFuzz_constructor_rejectsZeroAddresses(address,address,address) (runs: 10000, μ: 585620, ~: 585936)
[PASS] testFuzz_crossPathDoubleRelay(bytes32,bytes32,bool,bool) (runs: 10000, μ: 211021, ~: 211252)
[PASS] testFuzz_proposeOwner_success(address) (runs: 10000, μ: 36214, ~: 36214)
[PASS] testFuzz_relayOracleAnswer_correctPayouts(bytes32,bytes32,bool) (runs: 10000, μ: 212089, ~: 212401)
[PASS] testFuzz_relayOracleAnswer_doubleRelayReverts(bytes32,bytes32,bytes32,bool,bool) (runs: 10000, μ: 210493, ~: 210794)
[PASS] testFuzz_relayOracleAnswer_nonRelayerReverts(address,bytes32,bytes32,bool) (runs: 10000, μ: 17488, ~: 17489)
[PASS] testFuzz_relayOutcome_correctArgs(bytes32,bool) (runs: 10000, μ: 106444, ~: 96634)
[PASS] testFuzz_relayOutcome_doubleRelayReverts(bytes32,bool,bool) (runs: 10000, μ: 107544, ~: 97680)
[PASS] testFuzz_removeRelayer_nonRelayerReverts(address) (runs: 10000, μ: 15398, ~: 15398)
[PASS] testFuzz_setDiamond_success(address) (runs: 10000, μ: 19893, ~: 19894)
Suite result: ok. 13 passed; 0 failed; 0 skipped; finished in 7.66s (56.28s CPU time)

Ran 5 test suites in 7.67s (33.87s CPU time): 44 tests passed, 0 failed, 0 skipped (44 total tests)
