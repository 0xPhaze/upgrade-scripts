// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import "forge-std/Test.sol";

import {ExampleSetupScript} from "../src/ExampleSetupScript.sol";

contract TestExampleNFT is ExampleSetupScript {
    function __upgrade_scripts_init() internal override {
        __UPGRADE_SCRIPTS_BYPASS = true; // deploys contracts without any checks whatsoever
    }

    function setUp() public {
        setUpContracts();
    }

    function test_integration() public view {
        require(nft.owner() == address(this));

        require(keccak256(abi.encode(nft.name())) == keccak256(abi.encode("My NFT")));
        require(keccak256(abi.encode(nft.symbol())) == keccak256(abi.encode("NFTX")));
    }
}
