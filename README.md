# Upgrade Scripts (WIP)

Scripts to automate keeping track of active deployments and upgrades. Allows for:
- automatic contract deployments and proxy upgrades if the source has changed
- keeping track of all latest deployments and having one set-up for unit-tests, deployments and interactions
- storage layout compatibility checks on upgrades

These scripts use [ERC1967Proxy](https://github.com/0xPhaze/UDS/blob/master/src/proxy/ERC1967Proxy.sol).

## SetUpContract / SetUpProxy

This will make sure that `MyContract` is deployed and kept up-to-date.
If the `.creationCode` of `MyContract` ever changes, it will re-deploy the contract.
The latest deployments are stored in `deployments/{chainid}/deploy-latest.json`
with the contract's key being "MyContract".

```solidity
bytes memory creationCode = type(MyContract).creationCode;
address addr = setUpContract("MyContract", creationCode);
```

Note: the hash of `.creationCode` is compared instead of `addr.codehash`, because
this would not allow for reliable checks for contracts that use immutable variables that change for each implementation (such as using `address(this)` in EIP-2612's `DOMAIN_SEPARATOR`).

Similarly, a proxy can be deployed and kept up-to-date via `setUpProxy`.

```solidity
bytes memory initCall = abi.encodeWithSelector(MyContract.init.selector);
address proxy = setUpProxy("MyProxy", implementation, initCall);
```

Storage layout mappings are stored for each proxy implementation. These are used for
storage layout compatibility checks when running upgrades.
It is best to run through a complete example to understand when/how this is done.

## Keep Proxies Updated

This example is from [ExampleSetupScript](./example/src/ExampleSetupScript.sol).

```solidity
contract ExampleSetupScript is UpgradeScripts {
    ExampleNFT nft;

    function setUpContracts() internal {
        bytes memory initCall = abi.encodeWithSelector(ExampleNFT.init.selector, "My NFT", "NFTX");
        address implementation = setUpContract("MyNFTLogic", type(ExampleNFT).creationCode);
        nft = ExampleNFT(setUpProxy("ExampleNFT", implementation, initCall));
    }
}
```

Running this script on a live network will deploy the *implementation contract* and the *proxy contract* **once**.
Re-running this script without the implementation having changed **won't do anything**.
Re-running this script with a new implementation will detect the change and deploy a new implementation contract.
It will perform a **storage layout compatibility check** and **update your existing proxy** to point to it.
All *current* deployments are updated in `deployments/{chainid}/deploy-latest.json`.


## Example Tutorial using Anvil

First, make sure [Foundry](https://book.getfoundry.sh) is installed.

Clone the repository:
```sh
git clone https://github.com/0xPhaze/upgrade-scripts
```

Navigate to the example directory and install the dependencies
```sh
cd upgrade-scripts/example
forge install
```

Spin up a local anvil node **in a second terminal**.
```sh
anvil
```

Read through [deploy.s.sol](./example/script/deploy.s.sol) before running random scripts from the internet using `--ffi`.

In the example project root, run
```sh
UPGRADE_SCRIPTS_DRY_RUN=true forge script deploy --rpc-url http://127.0.0.1:8545 --private-key 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80 -vvvv --ffi
```
to go through a "dry-run" of the deploy scripts.
This connects to your running anvil node using the default account's private key.

Add `--broadcast` to the command to actually broadcast the transactions on-chain.
```sh
forge script deploy --rpc-url http://127.0.0.1:8545 --private-key 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80 -vvvv --broadcast --ffi
```

After a successful run, it should have created the file `./example/deployments/31337/deploy-latest.json` which keeps track of your up-to-date deployments. It also saves the contracts *creation code hash* and its *storage layout*.

Try running the command again. 
It will detect that no implementation has changed and thus not create any new transactions.

## Upgrading a Proxy Implementation

If any registered contracts' implementation changes, this should be detected and the corresponding proxies should automatically get updated on another call.
Try changing the implementation by, for example, uncommenting the line in `tokenURI()` in [ExampleNFT.sol](./example/src/ExampleNFT.sol) and re-running the script.

```solidity
contract ExampleNFT {
    ...
    function tokenURI(uint256 id) public view override returns (string memory uri) {
        // uri = "abcd";
    }
}
```

After a successful upgrade, running the script once more will not broadcast any additional transactions.

## Detecting Storage Layout Changes

A main security-feature of these scripts is to detect storage-layout changes.
Try uncommenting the following line in [ExampleNFT.sol](./example/src/ExampleNFT.sol).

```solidity
contract ExampleNFT is UUPSUpgrade, ERC721UDS, OwnableUDS {
    // uint256 public contractId = 1;
    ...
}
```

This adds an extra variable `contractId` to the storage of `ExampleNFT`.
If the script is run again (note that `--ffi` needs to be enabled),
it should notify that a storage layout change has been detected:
```diff
  Storage layout compatibility check [0x9fE46736679d2D9a65F0992F2272dE9f3c7fa6e0 <-> 0xDc64a140Aa3E981100a9becA4E685f962f0cF6C9]: fail
  
Diff:
  [...]

  If you believe the storage layout is compatible,
  add `if (block.chainid == 31337) isUpgradeSafe[0x9fE46736679d2D9a65F0992F2272dE9f3c7fa6e0][0xDc64a140Aa3E981100a9becA4E685f962f0cF6C9] = true;` to `run()` in your deploy script.
```

Note that, this can easily lead to false-positives, for example, when any variable is renamed
or when, like in this case, a variable is appended correctly to the end of existing storage.
Thus any positive detection here requires manually review.

Another peculiarity to account for is that, since dry-run uses `vm.prank` instead of `vm.broadcast`, there might be some differences when calculating the addresses of newly deployed contracts. Thus, sometimes, the scripts need to be run without a dry-run to get the correct address to be marked as "upgrade-safe".

Since we know it is safe, we can add the line
```solidity
if (block.chainid == 31337) isUpgradeSafe[0x9fE46736679d2D9a65F0992F2272dE9f3c7fa6e0][0xDc64a140Aa3E981100a9becA4E685f962f0cF6C9] = true;
```
to the start of `run()` in [deploy.s.sol](./example/script/deploy.s.sol).
If we re-run the script now, it will deploy a new implementation, perform the upgrade for our proxy and update the contract addresses in `deploy-latest.json`.

## Extra Notes

### Running on Mainnet
If not running on a testnet, adding `CONFIRM_DEPLOYMENT=true CONFIRM_UPGRADE=true forge ...` might be necessary. This is an additional safety measure. 

### Testing with Upgrade Scripts

In order to keep the deployment as close to the testing environment, 
it is generally helpful to share the same contract set-up scripts.

To disable any additional checks or logs that are not necessary when running `forge test`,
the function `upgradeScriptsInit()` can be overridden to
include `UPGRADE_SCRIPTS_BYPASS = true;`. This can be seen in [ExampleNFT.t.sol](./example/test/ExampleNFT.t.sol).
This bypasses all checks and simply deploys the contracts.

### Interacting with Deployed Contracts

To be able to interact with deployed contracts, the existing contracts can
be "attached" to the current environment (instead of re-deploying).
An example of how this can be done in order to mint an NFT from a deployed
address is shown in [mint.s.sol](./example/script/mint.s.sol). 
This requires the previous steps to be completed.

The script can then be run via:
```sh
forge script mint --rpc-url http://127.0.0.1:8545 --private-key 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80 -vvvv --broadcast
```

### Contract Storage Layout Incompatible Example

Here is an example of what a incompatible contract storage layout change could look like:

```diff
"label": "districts",                                          |   "label": "sharesRegistered",
"type": "t_mapping(t_uint256,t_struct(District)40351_storage)" |   "type": "t_mapping(t_uint256,t_bool)"
"astId": 40369,                                                |   "astId": 40531,
"label": "gangsters",                                          |   "label": "districts",
"type": "t_mapping(t_uint256,t_struct(Gangster)40314_storage)" |   "type": "t_mapping(t_uint256,t_struct(District)40514_storage)"
"astId": 40373,                                                |   "astId": 40536,
"label": "itemCost",                                           |   "label": "gangsters",
                                                               >   "type": "t_mapping(t_uint256,t_struct(Gangster)40477_storage)"
                                                               > },
                                                               > {
                                                               >   "astId": 40540,
                                                               >   "contract": "src/GangWar.sol:GangWar",
                                                               >   "label": "itemCost",
                                                               >   "offset": 0,
                                                               >   "slot": "7",
"astId": 40377,                                                |   "astId": 40544,
"slot": "7",                                                   |   "slot": "8",
```

Here, an additional `mapping(uint256 => bool) sharesRegistered` (right side) was inserted in a storage slot
where previously another mapping existed, shifting the slots of the other variables. 
The variable `itemCost`, previously `slot 7` (left side) is now located at `slot 8`.
Running an upgrade with this change would lead to storage layout conflicts.

Using some diff-tool viewer (such as vs-code's right-click > compare selected) can often paint a clearer picture.
![image](https://user-images.githubusercontent.com/103113487/186721360-6dee87fe-ad9a-431e-8d0a-2ad9ce601406.png)

## Notes and disclaimers
These scripts do not replace manual review and caution must be taken when upgrading contracts
in any case.
Make sure you understand what the scripts are doing. I am not responsible for any damages created.

Note that, it currently is not possible to detect whether `--broadcast` is enabled.
Thus the script can't reliably detect whether the transactions are only simulated or sent
on-chain. For that reason, `UPGRADE_SCRIPT_DRY_RUN=true` must ALWAYS be set when `--broadcast` is passed in.
Otherwise this will update `deploy-latest.json` with addresses that haven't actually been deployed yet and will complain on the next run.

When `deploy-latest.json` was updated with incorrect addresses for this reason, just delete the file and the incorrect previously created `deploy-{latestTimestamp}.json` (containing the highest latest timestamp) and copy the correct `.json` (second highest timestamp) to `deploy-latest.json`.

If anvil is restarted, these deployments will also be invalid.
Simply delete the corresponding folder `rm -rf deployments/31337` in this case.
