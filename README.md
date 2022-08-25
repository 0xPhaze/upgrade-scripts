# Upgrade Scripts

These scripts have only been tested with the [UDS repository](https://github.com/0xPhaze/UDS).
It is advised to run through an example.

Make sure [Foundry](https://book.getfoundry.sh) is installed.

## Example using Anvil

Clone the repository by running
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

Read through [deploy.s.sol](./example/script/deploy.s.sol) and make sense of the deploy script.

Run
```sh
UPGRADE_SCRIPTS_DRY_RUN=true forge script deploy --rpc-url http://127.0.0.1:8545 --private-key 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80 -vvvv --ffi
```
in the example project root
to go through a "dry-run" of the deploy scripts and make sure it runs correctly.
This connects to your running anvil node using the default account's private key.

Add `--broadcast` and `--ffi` to the command to actually send the transactions on-chain.
```sh
forge script deploy --rpc-url http://127.0.0.1:8545 --private-key 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80 -vvvv --broadcast --ffi
```
to deploy and set up the contracts locally.

After running successfully, it should have created [deploy-latest.json](./example/deployments/31337/deploy-latest.json) (keeps track of your up-to-date deployments) and a bunch of other data (used for running checks, such as storage layout changes).

Try out running the command again. 
It will detect that no implementation has changed and thus not create any new transactions.

## Changing implementation

If any registered contracts' implementation changes, this should be detected and the corresponding proxies should be updated.

Try changing the implementation by, for example, uncommenting the line in `tokenURI()` of `ExampleNFT` in [deploy.s.sol](./example/script/deploy.s.sol) and re-running the script.
```solidity
    function tokenURI(uint256 id) public view override returns (string memory uri) {
        // uri = "abcd";
    }
```

After successfully upgrading the contracts to the latest versions, running the script once more
should not create any additional changes/transactions.

## Changing storage layout of implementation

A main security-feature of these scripts is to detect storage-layout changes.

Try uncommenting the following line in `ExampleNFT` ([deploy.s.sol](./example/script/deploy.s.sol)).
```solidity
contract ExampleNFT is UUPSUpgrade, ERC721UDS, OwnableUDS {
    // uint256 public contractId = 1;
```

This adds an extra variable `contractId` to the storage of `ExampleNFT`.
If the script is run again (note that `--broadcast` and `--ffi` need to be enabled here),
it should output:
```diff
  Storage layout compatibility check [0x9fE46736679d2D9a65F0992F2272dE9f3c7fa6e0 <-> 0xDc64a140Aa3E981100a9becA4E685f962f0cF6C9]: fail
  
Diff:
  >         },
                                                                                      >     {
                                                                                      >       "astId": 18278,
                                                                                      >       "contract": "script/deploy.s.sol:ExampleNFT",
                                                                                      >       "label": "contractId",
                                                                                      >       "offset": 0,
                                                                                      >       "slot": "8",
                                                                                      >       "type": "t_uint256"
  If you believe the storage layout is compatible,
  add `if (block.chainid == 31337) isUpgradeSafe[0x9fE46736679d2D9a65F0992F2272dE9f3c7fa6e0][0xDc64a140Aa3E981100a9becA4E685f962f0cF6C9] = true;` to `run()` in your deploy script.
```

Note that this can easily lead to false-positives, for example, when any variable is renamed
or when, like in this case, a variable is appended correctly to the end of existing storage.
Thus any positive detection here will have to be manually review.

Another thing to account for is that, since dry-run uses `vm.prank` instead of `vm.broadcast`, there might be some differences when calculating the addresses of newly deployed contracts. Thus, when running without a dry-run, the address to mark as "upgrade-safe" can be a different one.

In our case, we know it is safe and can add
`if (block.chainid == 31337) isUpgradeSafe[0x9fE46736679d2D9a65F0992F2272dE9f3c7fa6e0][0xDc64a140Aa3E981100a9becA4E685f962f0cF6C9] = true;` to the start of `run()` in [deploy.s.sol](./example/script/deploy.s.sol).
If we re-run the script now, it will perform the upgrade for our proxy.


## Notes and disclaimers
These scripts do not replace manual review and caution must be taken when upgrading contracts
in any case.
Make sure you understand what the scripts are doing. I am not responsible for any damages created.

Note that, it currently is not possible to detect whether `--broadcast` is enabled.
Thus the script can't reliably detect whether the transactions are only simultated or sent
on-chain. For that reason, `DRY_RUN=true` must ALWAYS be passed in when `--broadcast` is set.
Otherwise this will update `deploy-latest.json` with addresses that don't actually exist.

When `deploy-latest.json` was updated with incorrect addresses for this reason, just delete the file and the incorrect `deploy-{newestTimestamp}.json` (that has the highest latest timestamp) and copy the second oldest `.json` containing the valid addresses.

Further note that, if anvil is restarted, these deployments will also be invalid.
To reset these in this case, just delete the corresponding folder `rm -rf deployments/31337`.