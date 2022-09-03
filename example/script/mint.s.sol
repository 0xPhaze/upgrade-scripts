// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "../src/ExampleSetupScript.sol";

/* 
# Anvil example

## Dry-run
forge script mint --rpc-url http://127.0.0.1:8545 --private-key 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80 -vvvv

## Broadcast enabled
forge script mint --rpc-url http://127.0.0.1:8545 --private-key 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80 -vvvv --broadcast
*/

contract mint is ExampleSetupScript {
    function setUpUpgradeScripts() internal override {
        // we only want to attach existing contracts
        // though if everything is up-to-date, this should be redundant
        UPGRADE_SCRIPTS_ATTACH_ONLY = true; // disables re-deploying/upgrading
    }

    function run() external {
        // run the setup scripts; attach contracts
        setUpContracts();

        vm.startBroadcast();

        // do stuff
        nft.mint(msg.sender);

        vm.stopBroadcast();
    }
}
