// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {ExampleNFT} from "./ExampleNFT.sol";

import {UpgradeScripts} from "upgrade-scripts/UpgradeScripts.sol";
import {ERC1967Proxy} from "openzeppelin-contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {UUPSUpgradeable} from "openzeppelin-contracts/proxy/utils/UUPSUpgradeable.sol";

contract ExampleSetupScript is UpgradeScripts {
    ExampleNFT nft;

    /// @dev using OZ's ERC1967Proxy
    function getDeployProxyCode(address implementation, bytes memory initCall)
        internal
        pure
        override
        returns (bytes memory)
    {
        return abi.encodePacked(type(ERC1967Proxy).creationCode, abi.encode(implementation, initCall));
    }

    /// @dev using OZ's UUPSUpgradeable function call
    function upgradeProxy(address proxy, address newImplementation) internal override {
        UUPSUpgradeable(proxy).upgradeTo(newImplementation);
    }

    // /// @dev override using forge's built-in create2 deployer (only works for specific chains, or: use your own!)
    // function deployCode(bytes memory code) internal override returns (address addr) {
    //     uint256 salt = 0x1234;

    //     assembly {
    //         addr := create2(0, add(code, 0x20), mload(code), salt)
    //     }
    // }

    function setUpContracts() internal {
        // encodes constructor call: `ExampleNFT(1)`
        bytes memory constructorArgs = abi.encode(uint256(1));
        address implementation = setUpContract("ExampleNFT", constructorArgs);

        // encodes function call: `ExampleNFT.init("My NFT", "NFTX")`
        bytes memory initCall = abi.encodeCall(ExampleNFT.init, ("My NFT", "NFTX"));
        address proxy = setUpProxy(implementation, initCall);

        nft = ExampleNFT(proxy);
    }

    function integrationTest() internal view {
        require(nft.owner() == msg.sender);

        require(keccak256(abi.encode(nft.name())) == keccak256(abi.encode("My NFT")));
        require(keccak256(abi.encode(nft.symbol())) == keccak256(abi.encode("NFTX")));
    }
}
