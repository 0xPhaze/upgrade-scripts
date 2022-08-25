// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import "forge-std/Script.sol";

// import "solmate/test/utils/mocks/MockERC721.sol";

// import "/Contract.sol";

/* 
# Mumbai
source .env && forge script deploy --rpc-url $RPC_MUMBAI --private-key $PRIVATE_KEY --with-gas-price 38gwei -vvvv
source .env && forge script deploy --rpc-url $RPC_MUMBAI --private-key $PRIVATE_KEY --verify --etherscan-api-key $POLYGONSCAN_KEY --with-gas-price 38gwei -vvvv --ffi --broadcast 

# Anvil
source .env && forge script deploy --rpc-url $RPC_ANVIL --private-key $PRIVATE_KEY_ANVIL 38gwei -vvvv
source .env && forge script deploy --rpc-url $RPC_ANVIL --private-key $PRIVATE_KEY_ANVIL 38gwei -vvvv --ffi --broadcast 
*/

contract deploy is Script {
    // Contract test;

    function run() external {
        vm.startBroadcast();

        // MockERC721 mock = new MockERC721("", "");

        vm.stopBroadcast();
    }

    function validate() internal {}
}
