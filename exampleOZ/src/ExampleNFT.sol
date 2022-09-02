// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {UUPSUpgradeable} from "openzeppelin-contracts/proxy/utils/UUPSUpgradeable.sol";
import {ERC721Upgradeable} from "openzeppelin-contracts-upgradeable/token/ERC721/ERC721Upgradeable.sol";
import {OwnableUpgradeable} from "openzeppelin-contracts-upgradeable/access/OwnableUpgradeable.sol";

contract ExampleNFT is UUPSUpgradeable, ERC721Upgradeable, OwnableUpgradeable {
    uint256 totalSupply;
    uint256 public immutable version;

    // uint256 public contractId = 1;

    constructor(uint256 version_) {
        version = version_;
        _disableInitializers();
    }

    function init(string memory name, string memory symbol) external initializer {
        __Ownable_init();
        __ERC721_init(name, symbol);
    }

    function tokenURI(uint256) public pure override returns (string memory uri) {
        // uri = "abcd";
    }

    function mint(address to) public {
        _mint(to, ++totalSupply);
    }

    function _authorizeUpgrade(address) internal override onlyOwner {}
}
