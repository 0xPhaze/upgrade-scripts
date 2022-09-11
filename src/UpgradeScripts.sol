// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import "forge-std/Script.sol";

import {UUPSUpgrade} from "UDS/proxy/UUPSUpgrade.sol";
import {LibEnumerableSet, Uint256Set} from "UDS/lib/LibEnumerableSet.sol";
import {ERC1967Proxy, ERC1967_PROXY_STORAGE_SLOT} from "UDS/proxy/ERC1967Proxy.sol";

/// @title Foundry Upgrade Scripts
/// @author 0xPhaze (https://github.com/0xPhaze/upgrade-scripts)
/// @notice Scripts for setting up and keeping track of deployments & proxies
contract UpgradeScripts is Script {
    using LibEnumerableSet for Uint256Set;

    struct ContractData {
        string key;
        address addr;
    }

    bool UPGRADE_SCRIPTS_RESET; // re-deploys all contracts
    bool UPGRADE_SCRIPTS_BYPASS; // deploys contracts without any checks whatsoever
    bool UPGRADE_SCRIPTS_DRY_RUN; // doesn't overwrite new deployments in deploy-latest.json
    bool UPGRADE_SCRIPTS_CONFIRM; // confirm deployments/upgrades when running on mainnet
    bool UPGRADE_SCRIPTS_ATTACH_ONLY; // doesn't deploy contracts, just attaches with checks
    bool UPGRADE_SCRIPTS_BYPASS_SAFETY; // bypass all upgrade safety checks

    // mappings chainid => ...
    mapping(uint256 => mapping(address => bool)) firstTimeDeployed; // set to true for contracts that are just deployed; useful for inits
    mapping(uint256 => mapping(address => mapping(address => bool))) isUpgradeSafe; // whether a contract => contract is deemed upgrade safe

    Uint256Set registeredChainIds; // chainids that contain registered contracts
    mapping(uint256 => ContractData[]) registeredContracts; // contracts registered through `setUpContract` or `setUpProxy`
    mapping(uint256 => mapping(address => string)) registeredContractName; // chainid => address => name mapping
    mapping(uint256 => mapping(string => address)) registeredContractAddress; // chainid => key => address mapping

    // cache for operations
    mapping(string => bool) __madeDir;
    mapping(uint256 => bool) __latestDeploymentsLoaded;
    mapping(uint256 => string) __latestDeploymentsJson;
    mapping(uint256 => mapping(address => bool)) __storageLayoutGenerated;

    constructor() {
        setUpUpgradeScripts(); // allows for environment variables to be set before initial load

        loadEnvVars();

        if (UPGRADE_SCRIPTS_BYPASS) return; // bypass any checks
        if (UPGRADE_SCRIPTS_ATTACH_ONLY) return; // bypass any further checks (doesn't require FFI)

        // enforce dry-run when ffi is disabled, as otherwise
        // deployments won't be able to be stored in `deploy-latest.json`
        if (!UPGRADE_SCRIPTS_DRY_RUN && !isFFIEnabled()) {
            UPGRADE_SCRIPTS_DRY_RUN = true;

            console.log("Dry-run enabled (`FFI=false`).");
        }
    }

    /* ------------- setUp ------------- */

    /// @dev allows for `UPGRADE_SCRIPTS_*` variables to be set in override
    function setUpUpgradeScripts() internal virtual {}

    /// @notice Sets-up a contract. If a previous deployment is found,
    ///         the creation-code-hash is checked against the stored contract's
    ///         hash and a new contract is deployed if it is outdated or no
    ///         previous deployment was found. Otherwise, it is simply attached.
    /// @param contractName name of the contract to be deployed (must be exact)
    /// @param constructorArgs abi-encoded constructor arguments
    /// @param key unique identifier to be used in logs
    /// @return implementation deployed or loaded contract implementation
    function setUpContract(
        string memory contractName,
        bytes memory constructorArgs,
        string memory key,
        bool attachOnly
    ) internal virtual returns (address implementation) {
        string memory keyOrContractName = bytes(key).length == 0 ? contractName : key;
        bytes memory creationCode = abi.encodePacked(getContractCode(contractName), constructorArgs);

        if (UPGRADE_SCRIPTS_BYPASS) {
            implementation = deployCodeWrapper(creationCode);

            vm.label(implementation, keyOrContractName);

            return implementation;
        }
        if (UPGRADE_SCRIPTS_ATTACH_ONLY) attachOnly = true;

        bool deployNew = UPGRADE_SCRIPTS_RESET;

        if (!deployNew) {
            implementation = loadLatestDeployedAddress(keyOrContractName);

            if (implementation != address(0)) {
                if (implementation.code.length == 0) {
                    console.log("Stored %s does not contain code.", contractLabel(contractName, implementation, key));
                    console.log("Make sure '%s' contains all the latest deployments.", getDeploymentsPath("deploy-latest.json")); // prettier-ignore

                    throwError("Invalid contract address.");
                }

                if (creationCodeHashMatches(implementation, keccak256(creationCode))) {
                    console.log("Stored %s up-to-date.", contractLabel(contractName, implementation, key));
                } else {
                    console.log("Implementation for %s changed.", contractLabel(contractName, implementation, key));

                    if (attachOnly) console.log("Keeping existing deployment (`attachOnly=true`).");
                    else deployNew = true;
                }
            } else {
                console.log("Existing implementation for %s not found.", contractLabel(contractName, implementation, key)); // prettier-ignore

                deployNew = true;

                if (UPGRADE_SCRIPTS_ATTACH_ONLY) throwError("Contract deployment is missing.");
            }
        }

        if (deployNew) {
            implementation = confirmDeployCode(creationCode);

            console.log("=> new %s.\n", contractLabel(contractName, implementation, key));

            saveCreationCodeHash(implementation, keccak256(creationCode));
        }

        registerContract(keyOrContractName, contractName, implementation);
    }

    /// @notice Sets-up a proxy. If a previous deployment is found,
    ///         it makes sure that the stored implementation matches the
    ///         current one. Includes checks for whether the implementation
    ///         is upgrade-compatible. If performing an upgrade, storage
    ///         layout is diff-checked. Throws if any changes are present.
    /// @param implementation address of the contract for delegatecalls
    /// @param initCall abi-encoded arguments for an initial delegatecall to be
    ///        performed during the contract's deployment
    /// @param key unique identifier to be used in logs
    /// @return proxy deployed or loaded proxy address
    function setUpProxy(
        address implementation,
        bytes memory initCall,
        string memory key,
        bool attachOnly
    ) internal virtual returns (address proxy) {
        string memory contractName = registeredContractName[block.chainid][implementation];
        string memory keyOrContractName = bytes(key).length == 0 ? string.concat(contractName, "Proxy") : key;

        // always run this check, as otherwise the error-message is confusing
        assertIsERC1967Upgrade(implementation, keyOrContractName);

        if (UPGRADE_SCRIPTS_BYPASS) {
            proxy = deployProxy(implementation, initCall);

            vm.label(proxy, keyOrContractName);

            return proxy;
        }
        if (UPGRADE_SCRIPTS_ATTACH_ONLY) attachOnly = true;

        // we require the contract name/type to be able to create a storage layout mapping
        // for the implementation tied to this proxy's address
        if (bytes(contractName).length == 0) {
            console.log("Could not identify proxy contract name/type for implementation %s [key: %s].", implementation, key); // prettier-ignore
            console.log("Make sure the implementation type was set up via `setUpContract` for its type to be registered."); // prettier-ignore
            console.log('Otherwise it can be set explicitly by adding `registeredContractName[%s] = "MyContract";`.', implementation); // prettier-ignore

            throwError("Could not identify contract type.");
        }

        bool deployNew = UPGRADE_SCRIPTS_RESET;

        if (!deployNew) {
            proxy = loadLatestDeployedAddress(keyOrContractName);

            if (proxy != address(0)) {
                address storedImplementation = loadProxyStoredImplementation(
                    proxy,
                    proxyLabel(proxy, contractName, address(0), key)
                );

                if (storedImplementation != implementation) {
                    console.log("Existing %s needs upgrade.", proxyLabel(proxy, contractName, storedImplementation, key)); // prettier-ignore

                    if (attachOnly) {
                        console.log("Keeping existing deployment (`attachOnly=true`).");
                    } else {
                        upgradeSafetyChecks(contractName, storedImplementation, implementation);

                        console.log("Upgrading %s.\n", proxyLabel(proxy, contractName, implementation, key));

                        confirmUpgradeProxy(proxy, implementation);
                    }
                } else {
                    console.log("Stored %s up-to-date.", proxyLabel(proxy, contractName, implementation, key));
                }
            } else {
                console.log("Existing %s not found.", proxyLabel(proxy, contractName, implementation, key));

                if (UPGRADE_SCRIPTS_ATTACH_ONLY) throwError("Contract deployment is missing.");

                deployNew = true;
            }
        }

        if (deployNew) {
            proxy = confirmDeployProxy(implementation, initCall);

            console.log("=> new %s.\n", proxyLabel(proxy, contractName, implementation, key));

            generateStorageLayoutFile(contractName, implementation);
        }

        registerContract(keyOrContractName, contractName, proxy);
    }

    /* ------------- overloads ------------- */

    function setUpContract(
        string memory contractName,
        bytes memory constructorArgs,
        string memory key
    ) internal virtual returns (address) {
        return setUpContract(contractName, constructorArgs, key, false);
    }

    function setUpContract(string memory contractName) internal virtual returns (address) {
        return setUpContract(contractName, "", "", false);
    }

    function setUpContract(string memory contractName, bytes memory constructorArgs)
        internal
        virtual
        returns (address)
    {
        return setUpContract(contractName, constructorArgs, "", false);
    }

    function setUpProxy(
        address implementation,
        bytes memory initCall,
        string memory key
    ) internal virtual returns (address) {
        return setUpProxy(implementation, initCall, key, false);
    }

    function setUpProxy(address implementation, bytes memory initCall) internal virtual returns (address) {
        return setUpProxy(implementation, initCall, "", false);
    }

    function setUpProxy(address implementation) internal virtual returns (address) {
        return setUpProxy(implementation, "", "", false);
    }

    /* ------------- snippets ------------- */

    function loadEnvVars() internal virtual {
        // silently bypass everything if set in the scripts
        if (!UPGRADE_SCRIPTS_BYPASS) {
            UPGRADE_SCRIPTS_RESET = tryLoadEnvBool(UPGRADE_SCRIPTS_RESET, "UPGRADE_SCRIPTS_RESET", "US_RESET");
            UPGRADE_SCRIPTS_BYPASS = tryLoadEnvBool(UPGRADE_SCRIPTS_BYPASS, "UPGRADE_SCRIPTS_BYPASS", "US_BYPASS");
            UPGRADE_SCRIPTS_DRY_RUN = tryLoadEnvBool(UPGRADE_SCRIPTS_DRY_RUN, "UPGRADE_SCRIPTS_DRY_RUN", "US_DRY_RUN");
            UPGRADE_SCRIPTS_CONFIRM = tryLoadEnvBool(UPGRADE_SCRIPTS_CONFIRM, "UPGRADE_SCRIPTS_CONFIRM", "US_CONFIRM");
            UPGRADE_SCRIPTS_ATTACH_ONLY = tryLoadEnvBool(UPGRADE_SCRIPTS_ATTACH_ONLY, "UPGRADE_SCRIPTS_ATTACH_ONLY", "US_ATTACH_ONLY"); // prettier-ignore

            if (
                UPGRADE_SCRIPTS_RESET ||
                UPGRADE_SCRIPTS_BYPASS ||
                UPGRADE_SCRIPTS_DRY_RUN ||
                UPGRADE_SCRIPTS_ATTACH_ONLY ||
                UPGRADE_SCRIPTS_CONFIRM
            ) console.log("");
        }
    }

    function tryLoadEnvBool(
        bool defaultVal,
        string memory varName,
        string memory varAlias
    ) internal virtual returns (bool val) {
        val = defaultVal;

        if (!val) {
            try vm.envBool(varName) returns (bool val_) {
                val = val_;
            } catch {
                try vm.envBool(varAlias) returns (bool val_) {
                    val = val_;
                } catch {}
            }
        }

        if (val) console.log("%s=true", varName);
    }

    function startBroadcastIfNotDryRun() internal {
        if (!UPGRADE_SCRIPTS_DRY_RUN) {
            vm.startBroadcast();
        } else {
            console.log("Disabling `vm.broadcast` (dry-run).\n");

            // need to start prank instead now to be consistent in "dry-run"
            vm.stopBroadcast();
            vm.startPrank(tx.origin);
        }
    }

    function loadLatestDeployedAddress(string memory key) internal virtual returns (address) {
        return loadLatestDeployedAddress(key, block.chainid);
    }

    function loadLatestDeployedAddress(string memory key, uint256 chainId) internal virtual returns (address) {
        if (!__latestDeploymentsLoaded[chainId]) {
            try vm.readFile(getDeploymentsPath("deploy-latest.json", chainId)) returns (string memory json) {
                __latestDeploymentsJson[chainId] = json;
            } catch {}
            __latestDeploymentsLoaded[chainId] = true;
        }

        if (bytes(__latestDeploymentsJson[chainId]).length != 0) {
            try vm.parseJson(__latestDeploymentsJson[chainId], string.concat(".", key)) returns (bytes memory data) {
                if (data.length == 32) return abi.decode(data, (address));
            } catch {}
        }

        return address(0);
    }

    function loadProxyStoredImplementation(address proxy) internal virtual returns (address) {
        return loadProxyStoredImplementation(proxy, "");
    }

    function loadProxyStoredImplementation(address proxy, string memory label)
        internal
        virtual
        returns (address implementation)
    {
        require(proxy.code.length != 0, string.concat("No code stored at ", label, "."));

        try vm.load(proxy, ERC1967_PROXY_STORAGE_SLOT) returns (bytes32 data) {
            implementation = address(uint160(uint256(data)));

            // note: proxies should never have implementation address(0) stored
            require(
                implementation != address(0),
                string.concat("Invalid existing implementation address(0) stored in ", label, ".")
            );
            require(
                UUPSUpgrade(implementation).proxiableUUID() == ERC1967_PROXY_STORAGE_SLOT,
                string.concat("Proxy ", label, " trying to upgrade to implementation with invalid proxiable UUID: ", vm.toString(implementation)) // prettier-ignore
            );
        } catch {
            // won't happen
            console.log("Contract %s not identified as a proxy", proxy);
        }
    }

    function generateStorageLayoutFile(string memory contractName, address implementation) internal virtual {
        if (__storageLayoutGenerated[block.chainid][implementation]) return;

        if (!isFFIEnabled()) {
            return console.log("SKIPPING storage layout mapping for %s (`FFI=false`).\n", contractLabel(contractName, implementation, '')); // prettier-ignore
        }

        console.log("Generating storage layout mapping for %s.\n", contractLabel(contractName, implementation, ""));

        // assert Contract exists
        getContractCode(contractName);

        // mkdir if not already
        mkdir(getDeploymentsPath("data/"));

        string[] memory script = new string[](4);
        script[0] = "forge";
        script[1] = "inspect";
        script[2] = contractName;
        script[3] = "storage-layout";

        bytes memory out = vm.ffi(script);

        vm.writeFile(getStorageLayoutFilePath(implementation), string(out));

        __storageLayoutGenerated[block.chainid][implementation] = true;
    }

    function upgradeSafetyChecks(
        string memory contractName,
        address oldImplementation,
        address newImplementation
    ) internal virtual {
        // note that `assertIsERC1967Upgrade(newImplementation);` is always run beforehand in any case

        if (!isFFIEnabled()) {
            return console.log("SKIPPING storage layout compatibility check [%s <-> %s] (`FFI=false`).", oldImplementation, newImplementation); // prettier-ignore
        }

        // note could skip if already generated during this script run
        generateStorageLayoutFile(contractName, newImplementation);

        if (UPGRADE_SCRIPTS_BYPASS_SAFETY) {
            return console.log("\nWARNING: Bypassing storage layout compatibility check [%s <-> %s] (`UPGRADE_SCRIPTS_BYPASS_SAFETY=true`).", oldImplementation, newImplementation); // prettier-ignore
        }
        if (isUpgradeSafe[block.chainid][oldImplementation][newImplementation]) {
            return console.log("Storage layout compatibility check [%s <-> %s]: Pass (`isUpgradeSafe=true`)", oldImplementation, newImplementation); // prettier-ignore
        }

        // @note give hint to skip via `isUpgradeSafe`?
        assertFileExists(getStorageLayoutFilePath(oldImplementation));
        assertFileExists(getStorageLayoutFilePath(newImplementation));

        string[] memory script = new string[](8);

        script[0] = "diff";
        script[1] = "-ayw";
        script[2] = "-W";
        script[3] = "180";
        script[4] = "--side-by-side";
        script[5] = "--suppress-common-lines";
        script[6] = getStorageLayoutFilePath(oldImplementation);
        script[7] = getStorageLayoutFilePath(newImplementation);

        bytes memory diff = vm.ffi(script);

        if (diff.length == 0) {
            console.log("Storage layout compatibility check [%s <-> %s]: Pass.", oldImplementation, newImplementation);
        } else {
            console.log("Storage layout compatibility check [%s <-> %s]: Fail", oldImplementation, newImplementation);
            console.log("\nDiff:");
            console.log(string(diff));

            console.log("\nIf you believe the storage layout is compatible, add the following to the beginning of `run()` in your deploy script.\n```"); // prettier-ignore
            console.log("isUpgradeSafe[%s][%s][%s] = true;\n```", block.chainid, oldImplementation, newImplementation); // prettier-ignore

            throwError("Contract storage layout changed and might not be compatible.");
        }

        isUpgradeSafe[block.chainid][oldImplementation][newImplementation] = true;
    }

    function saveCreationCodeHash(address addr, bytes32 creationCodeHash) internal virtual {
        if (UPGRADE_SCRIPTS_DRY_RUN) return;

        mkdir(getDeploymentsPath("data/"));

        string memory path = getCreationCodeHashFilePath(addr);

        vm.writeFile(path, vm.toString(creationCodeHash));
    }

    /// @dev .codehash is an improper check for contracts that use immutables
    function creationCodeHashMatches(address addr, bytes32 newCreationCodeHash) internal virtual returns (bool) {
        string memory path = getCreationCodeHashFilePath(addr);

        try vm.readFile(path) returns (string memory data) {
            bytes32 codehash = vm.parseBytes32(data);

            return codehash == newCreationCodeHash;
        } catch {}

        return false;
    }

    function fileExists(string memory file) internal virtual returns (bool exists) {
        string[] memory script = new string[](2);
        script[0] = "ls";
        script[1] = file;

        try vm.ffi(script) returns (bytes memory res) {
            if (bytes(res).length != 0) {
                exists = true;
            }
        } catch {}
    }

    function assertFileExists(string memory file) internal virtual {
        if (!fileExists(file)) {
            console.log("Unable to locate file '%s'.", file);
            console.log("You can bypass storage layout comparisons by setting `isUpgradeSafe[..] = true;`.", file);

            throwError("File does not exist.");
        }
    }

    function assertIsERC1967Upgrade(address implementation) internal virtual {
        assertIsERC1967Upgrade(implementation, "");
    }

    function assertIsERC1967Upgrade(address implementation, string memory contractName) internal virtual {
        if (implementation.code.length == 0) {
            console.log("No code stored at %s(%s).", contractName, implementation);

            throwError("Invalid contract address.");
        }

        try UUPSUpgrade(implementation).proxiableUUID() returns (bytes32 uuid) {
            if (uuid != ERC1967_PROXY_STORAGE_SLOT) {
                console.log("Invalid proxiable UUID for implementation %s(%s).", contractName, implementation);

                throwError("Contract not upgradeable.");
            }
        } catch {
            console.log("Contract %s(%s) does not implement proxiableUUID().", contractName, implementation);

            throwError("Contract not upgradeable.");
        }
    }

    function getContractCode(string memory contractName) internal virtual returns (bytes memory code) {
        try vm.getCode(contractName) returns (bytes memory code_) {
            code = code_;
        } catch (bytes memory reason) {
            try vm.getCode(string.concat(contractName, ".sol")) returns (bytes memory code_) {
                code = code_;
            } catch {
                assembly {
                    revert(add(0x20, reason), mload(reason))
                }
            }
        }

        if (code.length == 0) {
            console.log("Unable to find artifact '%s'.", contractName);
            console.log("Provide either a unique contract name ('MyContract'),");
            console.log("or an artifact location ('MyContract.sol:MyContract').");

            throwError("Contract does not exist.");
        }
    }

    /// @dev code for constructing ERC1967Proxy(address implementation, bytes memory initCall)
    /// makes an initial delegatecall to `implementation` with calldata `initCall` (if `initCall` != "")
    function getDeployProxyCode(address implementation, bytes memory initCall)
        internal
        view
        virtual
        returns (bytes memory)
    {
        this;
        return abi.encodePacked(type(ERC1967Proxy).creationCode, abi.encode(implementation, initCall));
    }

    function requireConfirmation() internal virtual {
        if (isTestnet() || UPGRADE_SCRIPTS_DRY_RUN || UPGRADE_SCRIPTS_BYPASS) return;

        if (UPGRADE_SCRIPTS_CONFIRM) {
            console.log("\nWARNING: `UPGRADE_SCRIPTS_CONFIRM=true` must be set for mainnet.");

            if (!UPGRADE_SCRIPTS_DRY_RUN) {
                console.log("Disabling `vm.broadcast`, continuing as dry-run.\n");

                UPGRADE_SCRIPTS_DRY_RUN = true;
            }

            // need to start prank instead now to be consistent in "dry-run"
            vm.stopBroadcast();
            vm.stopPrank();
            vm.startPrank(tx.origin);
        }
    }

    function confirmUpgradeProxy(address proxy, address newImplementation) internal virtual {
        requireConfirmation();

        upgradeProxy(proxy, newImplementation);
    }

    function upgradeProxy(address proxy, address newImplementation) internal virtual {
        UUPSUpgrade(proxy).upgradeToAndCall(newImplementation, "");
    }

    function confirmDeployProxy(address implementation, bytes memory initCall) internal virtual returns (address) {
        return confirmDeployCode(getDeployProxyCode(implementation, initCall));
    }

    function confirmDeployCode(bytes memory code) internal virtual returns (address) {
        requireConfirmation();

        return deployCodeWrapper(code);
    }

    function deployProxy(address implementation, bytes memory initCall) internal virtual returns (address) {
        return deployCodeWrapper(getDeployProxyCode(implementation, initCall));
    }

    function deployCodeWrapper(bytes memory code) internal virtual returns (address addr) {
        addr = deployCode(code);

        firstTimeDeployed[block.chainid][addr] = true;

        require(addr.code.length != 0, "Failed to deploy code.");
    }

    /* ------------- utils ------------- */

    function isFirstTimeDeployed(address addr) internal virtual returns (bool) {
        return firstTimeDeployed[block.chainid][addr];
    }

    function deployCode(bytes memory code) internal virtual returns (address addr) {
        assembly {
            addr := create(0, add(code, 0x20), mload(code))
        }
    }

    function hasCode(address addr) internal view virtual returns (bool hasCode_) {
        assembly {
            hasCode_ := iszero(iszero(extcodesize(addr)))
        }
    }

    function isTestnet() internal view virtual returns (bool) {
        uint256 chainId = block.chainid;

        if (chainId == 4) return true; // Rinkeby
        if (chainId == 5) return true; // Goerli
        if (chainId == 420) return true; // Optimism
        if (chainId == 31_337) return true; // Anvil
        if (chainId == 31_338) return true; // Anvil
        if (chainId == 80_001) return true; // Mumbai
        if (chainId == 421_611) return true; // Arbitrum
        if (chainId == 11_155_111) return true; // Sepolia

        return false;
    }

    function isFFIEnabled() internal virtual returns (bool) {
        string[] memory script = new string[](1);
        script[0] = "echo";

        try vm.ffi(script) {
            return true;
        } catch {
            return false;
        }
    }

    function mkdir(string memory path) internal virtual {
        if (__madeDir[path]) return;

        string[] memory script = new string[](3);
        script[0] = "mkdir";
        script[1] = "-p";
        script[2] = path;

        vm.ffi(script);

        __madeDir[path] = true;
    }

    /// @dev throwing error like this, because sometimes foundry won't display any logs otherwise
    function throwError(string memory message) internal view {
        if (bytes(message).length != 0) console.log("\nError: %s", message);

        // Must revert if not dry run to cancel broadcasting transactions.
        if (!UPGRADE_SCRIPTS_DRY_RUN) revert(string.concat(message, '\nEnable dry-run (`UPGRADE_SCRIPTS_DRY_RUN=true`) if the error message did not show.')); // prettier-ignore

        // Sometimes Forge does not display the complete message then..
        // That's why we return instead.
        assembly {
            return(0, 0)
        }
    }

    /* ------------- contract registry ------------- */

    function registerContract(
        string memory key,
        string memory name,
        address addr
    ) internal virtual {
        uint256 chainId = block.chainid;

        if (registeredContractAddress[chainId][key] != address(0)) {
            console.log("Duplicate entry for key [%s] found when registering contract.", key);
            console.log("Found: %s(%s)", key, registeredContractAddress[chainId][key]);

            throwError("Duplicate key.");
        }

        registeredChainIds.add(chainId);

        registeredContractName[chainId][addr] = name;
        registeredContractAddress[chainId][key] = addr;

        registeredContracts[chainId].push(ContractData({key: key, addr: addr}));

        vm.label(addr, key);
    }

    function logDeployments() internal view virtual {
        title("Registered Contracts");

        for (uint256 i; i < registeredChainIds.length(); i++) {
            uint256 chainId = registeredChainIds.at(i);

            console.log("Chain id %s:\n", chainId);
            for (uint256 j; j < registeredContracts[chainId].length; j++) {
                console.log("%s=%s", registeredContracts[chainId][j].key, registeredContracts[chainId][j].addr);
            }

            console.log("");
        }
    }

    function generateRegisteredContractsJson(uint256 chainId) internal virtual returns (string memory json) {
        if (registeredContracts[chainId].length == 0) return "";

        json = string.concat("{\n", '  "git-commit-hash": "', getGitCommitHash(), '",\n');

        for (uint256 i; i < registeredContracts[chainId].length; i++) {
            json = string.concat(
                json,
                '  "',
                registeredContracts[chainId][i].key,
                '": "',
                vm.toString(registeredContracts[chainId][i].addr),
                i + 1 == registeredContracts[chainId].length ? '"\n' : '",\n'
            );
        }
        json = string.concat(json, "}");
    }

    function storeLatestDeployments() internal virtual {
        if (!UPGRADE_SCRIPTS_DRY_RUN) {
            for (uint256 i; i < registeredChainIds.length(); i++) {
                uint256 chainId = registeredChainIds.at(i);

                string memory json = generateRegisteredContractsJson(chainId);

                if (keccak256(bytes(json)) == keccak256(bytes(__latestDeploymentsJson[chainId]))) {
                    console.log("No changes detected.", chainId);
                } else {
                    mkdir(getDeploymentsPath("", chainId));

                    vm.writeFile(getDeploymentsPath(string.concat("deploy-latest.json"), chainId), json);
                    vm.writeFile(getDeploymentsPath(string.concat("deploy-", vm.toString(block.timestamp), ".json"), chainId), json); // prettier-ignore

                    console.log("Deployments saved to %s.", getDeploymentsPath("deploy-latest.json", chainId)); // prettier-ignore
                }
            }
        }
    }

    function getGitCommitHash() internal virtual returns (string memory) {
        string[] memory script = new string[](3);
        script[0] = "git";
        script[1] = "rev-parse";
        script[2] = "HEAD";

        bytes memory hash = vm.ffi(script);

        if (hash.length != 20) {
            console.log("Unable to get commit hash.");
            return "";
        }

        string memory hashStr = vm.toString(hash);

        // remove the "0x" prefix
        assembly {
            mstore(add(hashStr, 2), sub(mload(hashStr), 2))
            hashStr := add(hashStr, 2)
        }
        return hashStr;
    }

    /* ------------- filePath ------------- */

    function getDeploymentsPath(string memory path) internal virtual returns (string memory) {
        return getDeploymentsPath(path, block.chainid);
    }

    function getDeploymentsPath(string memory path, uint256 chainId) internal virtual returns (string memory) {
        return string.concat("deployments/", vm.toString(chainId), "/", path);
    }

    function getCreationCodeHashFilePath(address addr) internal virtual returns (string memory) {
        return getDeploymentsPath(string.concat("data/", vm.toString(addr), ".creation-code-hash"));
    }

    function getStorageLayoutFilePath(address addr) internal virtual returns (string memory) {
        return getDeploymentsPath(string.concat("data/", vm.toString(addr), ".storage-layout"));
    }

    /* ------------- prints ------------- */

    function title(string memory name) internal view virtual {
        console.log("\n==========================");
        console.log("%s:\n", name);
    }

    function contractLabel(
        string memory contractName,
        address addr,
        string memory key
    ) internal virtual returns (string memory) {
        return
            string.concat(
                contractName,
                addr == address(0) ? "" : string.concat("(", vm.toString(addr), ")"),
                bytes(key).length == 0 ? "" : string.concat(" [", key, "]")
            );
    }

    function proxyLabel(
        address proxy,
        string memory contractName,
        address implementation,
        string memory key
    ) internal virtual returns (string memory) {
        return
            string.concat(
                "Proxy::",
                contractName,
                proxy == address(0)
                    ? ""
                    : string.concat(
                        "(",
                        vm.toString(proxy),
                        implementation == address(0) ? "" : string.concat(" -> ", vm.toString(implementation)),
                        ")"
                    ),
                bytes(key).length == 0 ? "" : string.concat(" [", key, "]")
            );
    }
}
