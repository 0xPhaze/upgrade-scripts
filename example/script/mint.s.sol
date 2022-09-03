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
        // We only want to attach existing contracts.
        // Though if everything is up-to-date, this should be redundant and not needed.
        UPGRADE_SCRIPTS_ATTACH_ONLY = true; // disables re-deploying/upgrading

        // The following variables can all be set to change the behavior of the scripts.
        // These can also all be set through passing the argument in the command line
        // e.g: UPGRADE_SCRIPTS_RESET=true forge script ...

        // bool UPGRADE_SCRIPTS_RESET; // re-deploys all contracts
        // bool UPGRADE_SCRIPTS_BYPASS; // deploys contracts without any checks whatsoever
        // bool UPGRADE_SCRIPTS_DRY_RUN; // doesn't overwrite new deployments in deploy-latest.json
        // bool UPGRADE_SCRIPTS_ATTACH_ONLY; // doesn't deploy contracts, just attaches with checks
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
