// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {ERC721UDS} from "UDS/tokens/ERC721UDS.sol";
import {OwnableUDS} from "UDS/auth/OwnableUDS.sol";
import {UUPSUpgrade} from "UDS/proxy/UUPSUpgrade.sol";

contract ExampleNFT is UUPSUpgrade, ERC721UDS, OwnableUDS {
    uint256 totalSupply;
    uint256 public immutable version;

    // uint256 public contractId = 1;

    constructor(uint256 version_) {
        version = version_;
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
