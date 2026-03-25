Compiler run successful!

Ran 3 tests for test/invariant/LzCrossChainReceiverInvariant.t.sol:LzCrossChainReceiverInvariantTest
[PASS] invariant_bridgeCallsNonNegative() (runs: 2048, calls: 204800, reverts: 0)

╭-----------------------------+-----------------------+-------+---------+----------╮
| Contract                    | Selector              | Calls | Reverts | Discards |
+==================================================================================+
| LzCrossChainReceiverHandler | receiveMessage        | 68244 | 0       | 0        |
|-----------------------------+-----------------------+-------+---------+----------|
| LzCrossChainReceiverHandler | receiveMessageFailing | 67917 | 0       | 0        |
|-----------------------------+-----------------------+-------+---------+----------|
| LzCrossChainReceiverHandler | removeFailedRelay     | 68639 | 0       | 0        |
╰-----------------------------+-----------------------+-------+---------+----------╯

[PASS] invariant_ownerUnchanged() (runs: 2048, calls: 204800, reverts: 0)

╭-----------------------------+-----------------------+-------+---------+----------╮
| Contract                    | Selector              | Calls | Reverts | Discards |
+==================================================================================+
| LzCrossChainReceiverHandler | receiveMessage        | 68201 | 0       | 0        |
|-----------------------------+-----------------------+-------+---------+----------|
| LzCrossChainReceiverHandler | receiveMessageFailing | 68256 | 0       | 0        |
|-----------------------------+-----------------------+-------+---------+----------|
| LzCrossChainReceiverHandler | removeFailedRelay     | 68343 | 0       | 0        |
╰-----------------------------+-----------------------+-------+---------+----------╯

[PASS] invariant_peerUnchanged() (runs: 2048, calls: 204800, reverts: 0)

╭-----------------------------+-----------------------+-------+---------+----------╮
| Contract                    | Selector              | Calls | Reverts | Discards |
+==================================================================================+
| LzCrossChainReceiverHandler | receiveMessage        | 68108 | 0       | 0        |
|-----------------------------+-----------------------+-------+---------+----------|
| LzCrossChainReceiverHandler | receiveMessageFailing | 68714 | 0       | 0        |
|-----------------------------+-----------------------+-------+---------+----------|
| LzCrossChainReceiverHandler | removeFailedRelay     | 67978 | 0       | 0        |
╰-----------------------------+-----------------------+-------+---------+----------╯

Suite result: ok. 3 passed; 0 failed; 0 skipped; finished in 68.01s (198.07s CPU time)

Ran 3 tests for test/invariant/UmaOracleAdapterInvariant.t.sol:UmaOracleAdapterInvariantTest
[PASS] invariant_bondsSentToOov3() (runs: 2048, calls: 204800, reverts: 0)

╭-------------------------+--------------------+-------+---------+----------╮
| Contract                | Selector           | Calls | Reverts | Discards |
+===========================================================================+
| UmaOracleAdapterHandler | cancelQuestion     | 68425 | 0       | 0        |
|-------------------------+--------------------+-------+---------+----------|
| UmaOracleAdapterHandler | initializeQuestion | 68298 | 0       | 0        |
|-------------------------+--------------------+-------+---------+----------|
| UmaOracleAdapterHandler | settleQuestion     | 68077 | 0       | 0        |
╰-------------------------+--------------------+-------+---------+----------╯

[PASS] invariant_ownerUnchanged() (runs: 2048, calls: 204800, reverts: 0)

╭-------------------------+--------------------+-------+---------+----------╮
| Contract                | Selector           | Calls | Reverts | Discards |
+===========================================================================+
| UmaOracleAdapterHandler | cancelQuestion     | 68035 | 0       | 0        |
|-------------------------+--------------------+-------+---------+----------|
| UmaOracleAdapterHandler | initializeQuestion | 68508 | 0       | 0        |
|-------------------------+--------------------+-------+---------+----------|
| UmaOracleAdapterHandler | settleQuestion     | 68257 | 0       | 0        |
╰-------------------------+--------------------+-------+---------+----------╯

[PASS] invariant_resolvedQuestionsHaveCreator() (runs: 2048, calls: 204800, reverts: 0)

╭-------------------------+--------------------+-------+---------+----------╮
| Contract                | Selector           | Calls | Reverts | Discards |
+===========================================================================+
| UmaOracleAdapterHandler | cancelQuestion     | 67960 | 0       | 0        |
|-------------------------+--------------------+-------+---------+----------|
| UmaOracleAdapterHandler | initializeQuestion | 68281 | 0       | 0        |
|-------------------------+--------------------+-------+---------+----------|
| UmaOracleAdapterHandler | settleQuestion     | 68559 | 0       | 0        |
╰-------------------------+--------------------+-------+---------+----------╯

Suite result: ok. 3 passed; 0 failed; 0 skipped; finished in 177.14s (322.79s CPU time)

Ran 5 tests for test/invariant/BridgeReceiverInvariant.t.sol:BridgeReceiverInvariantTest
[PASS] invariant_diamondUnchanged() (runs: 2048, calls: 204800, reverts: 0)

╭-----------------------+---------------------+-------+---------+----------╮
| Contract              | Selector            | Calls | Reverts | Discards |
+==========================================================================+
| BridgeReceiverHandler | relayFromNonRelayer | 68041 | 0       | 6        |
|-----------------------+---------------------+-------+---------+----------|
| BridgeReceiverHandler | relayOracleAnswer   | 68670 | 0       | 0        |
|-----------------------+---------------------+-------+---------+----------|
| BridgeReceiverHandler | relayOutcome        | 68095 | 0       | 0        |
╰-----------------------+---------------------+-------+---------+----------╯

[PASS] invariant_ownerUnchanged() (runs: 2048, calls: 204800, reverts: 0)

╭-----------------------+---------------------+-------+---------+----------╮
| Contract              | Selector            | Calls | Reverts | Discards |
+==========================================================================+
| BridgeReceiverHandler | relayFromNonRelayer | 68556 | 0       | 12       |
|-----------------------+---------------------+-------+---------+----------|
| BridgeReceiverHandler | relayOracleAnswer   | 68306 | 0       | 0        |
|-----------------------+---------------------+-------+---------+----------|
| BridgeReceiverHandler | relayOutcome        | 67950 | 0       | 0        |
╰-----------------------+---------------------+-------+---------+----------╯

[PASS] invariant_registerAndReportPayoutsPaired() (runs: 2048, calls: 204800, reverts: 0)

╭-----------------------+---------------------+-------+---------+----------╮
| Contract              | Selector            | Calls | Reverts | Discards |
+==========================================================================+
| BridgeReceiverHandler | relayFromNonRelayer | 68269 | 0       | 12       |
|-----------------------+---------------------+-------+---------+----------|
| BridgeReceiverHandler | relayOracleAnswer   | 68100 | 0       | 0        |
|-----------------------+---------------------+-------+---------+----------|
| BridgeReceiverHandler | relayOutcome        | 68443 | 0       | 0        |
╰-----------------------+---------------------+-------+---------+----------╯

[PASS] invariant_relayCountMatchesDiamondCalls() (runs: 2048, calls: 204800, reverts: 0)

╭-----------------------+---------------------+-------+---------+----------╮
| Contract              | Selector            | Calls | Reverts | Discards |
+==========================================================================+
| BridgeReceiverHandler | relayFromNonRelayer | 68153 | 0       | 17       |
|-----------------------+---------------------+-------+---------+----------|
| BridgeReceiverHandler | relayOracleAnswer   | 68247 | 0       | 0        |
|-----------------------+---------------------+-------+---------+----------|
| BridgeReceiverHandler | relayOutcome        | 68417 | 0       | 0        |
╰-----------------------+---------------------+-------+---------+----------╯

[PASS] invariant_relayedFlagsConsistent() (runs: 2048, calls: 204800, reverts: 0)

╭-----------------------+---------------------+-------+---------+----------╮
| Contract              | Selector            | Calls | Reverts | Discards |
+==========================================================================+
| BridgeReceiverHandler | relayFromNonRelayer | 67908 | 0       | 9        |
|-----------------------+---------------------+-------+---------+----------|
| BridgeReceiverHandler | relayOracleAnswer   | 68226 | 0       | 0        |
|-----------------------+---------------------+-------+---------+----------|
| BridgeReceiverHandler | relayOutcome        | 68675 | 0       | 0        |
╰-----------------------+---------------------+-------+---------+----------╯

Suite result: ok. 5 passed; 0 failed; 0 skipped; finished in 185.64s (411.68s CPU time)

Ran 4 tests for test/invariant/ChainlinkPriceResolverInvariant.t.sol:ChainlinkPriceResolverInvariantTest
[PASS] invariant_diamondCallsMatchSettled() (runs: 2048, calls: 204800, reverts: 0)

╭-------------------------------+----------------+-------+---------+----------╮
| Contract                      | Selector       | Calls | Reverts | Discards |
+=============================================================================+
| ChainlinkPriceResolverHandler | cancelQuestion | 68465 | 0       | 0        |
|-------------------------------+----------------+-------+---------+----------|
| ChainlinkPriceResolverHandler | createQuestion | 68284 | 0       | 0        |
|-------------------------------+----------------+-------+---------+----------|
| ChainlinkPriceResolverHandler | settleQuestion | 68051 | 0       | 0        |
╰-------------------------------+----------------+-------+---------+----------╯

[PASS] invariant_ownerUnchanged() (runs: 2048, calls: 204800, reverts: 0)

╭-------------------------------+----------------+-------+---------+----------╮
| Contract                      | Selector       | Calls | Reverts | Discards |
+=============================================================================+
| ChainlinkPriceResolverHandler | cancelQuestion | 68384 | 0       | 0        |
|-------------------------------+----------------+-------+---------+----------|
| ChainlinkPriceResolverHandler | createQuestion | 68545 | 0       | 0        |
|-------------------------------+----------------+-------+---------+----------|
| ChainlinkPriceResolverHandler | settleQuestion | 67871 | 0       | 0        |
╰-------------------------------+----------------+-------+---------+----------╯

[PASS] invariant_pendingCountConsistency() (runs: 2048, calls: 204800, reverts: 0)

╭-------------------------------+----------------+-------+---------+----------╮
| Contract                      | Selector       | Calls | Reverts | Discards |
+=============================================================================+
| ChainlinkPriceResolverHandler | cancelQuestion | 68593 | 0       | 0        |
|-------------------------------+----------------+-------+---------+----------|
| ChainlinkPriceResolverHandler | createQuestion | 67899 | 0       | 0        |
|-------------------------------+----------------+-------+---------+----------|
| ChainlinkPriceResolverHandler | settleQuestion | 68308 | 0       | 0        |
╰-------------------------------+----------------+-------+---------+----------╯

[PASS] invariant_resolvedNotPending() (runs: 2048, calls: 204800, reverts: 0)

╭-------------------------------+----------------+-------+---------+----------╮
| Contract                      | Selector       | Calls | Reverts | Discards |
+=============================================================================+
| ChainlinkPriceResolverHandler | cancelQuestion | 68003 | 0       | 0        |
|-------------------------------+----------------+-------+---------+----------|
| ChainlinkPriceResolverHandler | createQuestion | 68267 | 0       | 0        |
|-------------------------------+----------------+-------+---------+----------|
| ChainlinkPriceResolverHandler | settleQuestion | 68530 | 0       | 0        |
╰-------------------------------+----------------+-------+---------+----------╯

Suite result: ok. 4 passed; 0 failed; 0 skipped; finished in 214.35s (380.76s CPU time)

Ran 4 test suites in 214.35s (645.13s CPU time): 15 tests passed, 0 failed, 0 skipped (15 total tests)
