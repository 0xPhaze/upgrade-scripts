// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import "forge-std/Script.sol";

import "upgrade-scripts/UpgradeScripts.sol";
import "./ExampleNFT.sol";

contract ExampleSetupScript is UpgradeScripts {
    ExampleNFT nft;

    function setUpContracts() internal {
        bytes memory initCall = abi.encodeWithSelector(ExampleNFT.init.selector, "My NFT", "NFTX");
        address implementation = setUpContract("MyNFT_Implementation", "ExampleNFT", type(ExampleNFT).creationCode); // prettier-ignore
        nft = ExampleNFT(setUpProxy("myNFT", "ExampleNFT", implementation, initCall));
    }

    function integrationTest() internal view {
        require(nft.owner() == msg.sender);

        require(keccak256(abi.encode(nft.name())) == keccak256(abi.encode("My NFT")));
        require(keccak256(abi.encode(nft.symbol())) == keccak256(abi.encode("NFTX")));
    }
}
