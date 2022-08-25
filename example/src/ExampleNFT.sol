// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import {ERC721UDS} from "UDS/tokens/ERC721UDS.sol";
import {OwnableUDS} from "UDS/auth/OwnableUDS.sol";
import {UUPSUpgrade} from "UDS/proxy/UUPSUpgrade.sol";

contract ExampleNFT is UUPSUpgrade, ERC721UDS, OwnableUDS {
    uint256 public contractId = 1;

    function init(string calldata name, string calldata symbol) external initializer {
        __Ownable_init();
        __ERC721_init(name, symbol);
    }

    function tokenURI(uint256 id) public view override returns (string memory uri) {
        // uri = "abcd";
    }

    function mint(address to, uint256 id) public {
        _mint(to, id);
    }

    function _authorizeUpgrade() internal override onlyOwner {}
}
