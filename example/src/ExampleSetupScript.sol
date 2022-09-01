// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {ExampleNFT} from "./ExampleNFT.sol";
import {UpgradeScripts} from "upgrade-scripts/UpgradeScripts.sol";

contract ExampleSetupScript is UpgradeScripts {
    ExampleNFT nft;

    function setUpContracts() internal {
        // if the constructor takes any arguments use:
        // bytes memory creationCode = abi.encodePacked(type(ExampleNFT).creationCode, abi.encode(arg1, arg2));
        // bytes memory creationCode = type(ExampleNFT).creationCode;

        bytes memory constructorArgs = abi.encode(uint256(1));
        address implementation = setUpContract("ExampleNFT", constructorArgs);

        // encode `ExampleNFT.init("My NFT", "NFTX")`
        bytes memory initCall = abi.encodeWithSelector(ExampleNFT.init.selector, "My NFT", "NFTX");
        nft = ExampleNFT(setUpProxy("ExampleNFT", implementation, initCall));
    }

    function integrationTest() internal view {
        require(nft.owner() == msg.sender);

        require(keccak256(abi.encode(nft.name())) == keccak256(abi.encode("My NFT")));
        require(keccak256(abi.encode(nft.symbol())) == keccak256(abi.encode("NFTX")));
    }
}
