// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "../src/ExampleSetupScript.sol";

/* 
# Anvil example

## Dry-run
forge script deploy --rpc-url http://127.0.0.1:8545 --private-key 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80 -vvvv --ffi

## FFI and broadcast enabled
forge script deploy --rpc-url http://127.0.0.1:8545 --private-key 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80 -vvvv --broadcast --ffi
*/

contract deploy is ExampleSetupScript {
    function run() external {
        // uncommenting this line would mark the two contracts as having a compatible storage layout
        // if (block.chainid == 31337) isUpgradeSafe[0x9fE46736679d2D9a65F0992F2272dE9f3c7fa6e0][0xDc64a140Aa3E981100a9becA4E685f962f0cF6C9] = true; // prettier-ignore

        // will run `vm.startBroadcast();` if ffi is enabled
        // ffi is required for running storage layout compatibility checks
        // if ffi is disabled, it will enter "dry-run" and
        // run `vm.startPrank(msg.sender)` instead for the script to be consistent
        startBroadcastIfNotDryRun();

        // run the setup scripts
        setUpContracts();

        // we don't need broadcast from here on
        vm.stopBroadcast();

        // run an "integration test"
        integrationTest();

        // log all current deployments
        logDeployments();
        // store these in `deployments/{chainid}/deploy-latest.json` (if not dry-run)
        storeLatestDeployments();
    }
}
