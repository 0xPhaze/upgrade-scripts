// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import "forge-std/Script.sol";

import "../src/ExampleSetupScript.sol";

/* 
# Anvil example

## Dry-run
forge script attach --rpc-url http://127.0.0.1:8545 --private-key 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80 -vvvv

## FFI and broadcast enabled
forge script attach --rpc-url http://127.0.0.1:8545 --private-key 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80 -vvvv --broadcast
*/

contract deploy is ExampleSetupScript {
    function __upgrade_scripts_init() internal override {
        __UPGRADE_SCRIPTS_ATTACH = true; // we only want to load and set up existing contracts
        super.__upgrade_scripts_init();
    }

    function run() external {
        // run the setup scripts; attach contracts
        setUpContracts();

        vm.startBroadcast();

        // do stuff
        nft.mint(msg.sender, 1);

        vm.stopBroadcast();
    }
}
