// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import "forge-std/Script.sol";

import {UUPSUpgrade} from "UDS/proxy/UUPSUpgrade.sol";
import {ERC1967Proxy, ERC1967_PROXY_STORAGE_SLOT} from "UDS/proxy/ERC1967Proxy.sol";

interface VmParseJson {
    function parseJson(string calldata, string calldata) external returns (bytes memory);

    function parseJson(string calldata) external returns (bytes memory);
}

contract UpgradeScripts is Script {
    struct ContractData {
        string name;
        address addr;
    }

    bool UPGRADE_SCRIPTS_BYPASS; // deploys contracts without any checks whatsoever
    bool UPGRADE_SCRIPTS_DRY_RUN; // doesn't overwrite new deployments in deploy-latest.json
    bool UPGRADE_SCRIPTS_ATTACH_ONLY; // doesn't deploy contracts, just attaches with checks

    string __latestDeploymentsJson;
    bool __latestDeploymentsJsonLoaded;

    ContractData[] registeredContracts; // contracts registered through `setUpContract` or `setUpProxy`
    mapping(address => string) registeredContractName; // address => name mapping
    mapping(string => address) registeredContractAddress; // name => address mapping

    mapping(address => bool) firstTimeDeployed; // set to true for contracts that are just deployed; useful for inits
    mapping(address => bool) storageLayoutGenerated; // cache to not repeat slow layout generation
    mapping(address => mapping(address => bool)) isUpgradeSafe; // whether a contract => contract is deemed upgrade safe

    constructor() {
        upgradeScriptsInit(); // allows for override

        loadEnvVars();

        if (UPGRADE_SCRIPTS_BYPASS) return; // bypass any checks
        if (UPGRADE_SCRIPTS_ATTACH_ONLY) return; // bypass any further checks

        // enforce dry-run when ffi is disabled, since otherwise
        // deployments won't be able to be logged in `deploy-latest.json`
        if (!isFFIEnabled()) {
            if (!UPGRADE_SCRIPTS_DRY_RUN) {
                UPGRADE_SCRIPTS_DRY_RUN = true;
                console.log("Dry-run enabled (`FFI=false`).");
            }
        } else {
            // make sure the 'deployments' directory exists
            mkdir(getDeploymentsDataPath(""));
        }
    }

    function upgradeScriptsInit() internal virtual {}

    function loadEnvVars() internal virtual {
        try vm.envBool("UPGRADE_SCRIPTS_DRY_RUN") returns (bool val) {
            UPGRADE_SCRIPTS_DRY_RUN = val;
            if (val) console.log("UPGRADE_SCRIPTS_DRY_RUN=true");
        } catch {}
        try vm.envBool("UPGRADE_SCRIPTS_BYPASS") returns (bool val) {
            UPGRADE_SCRIPTS_BYPASS = val;
            if (val) console.log("UPGRADE_SCRIPTS_BYPASS=true");
        } catch {}
        try vm.envBool("UPGRADE_SCRIPTS_ATTACH_ONLY") returns (bool val) {
            UPGRADE_SCRIPTS_ATTACH_ONLY = val;
            if (val) console.log("UPGRADE_SCRIPTS_ATTACH_ONLY=true");
        } catch {}
    }

    /* ------------- setUp ------------- */

    function getContractCode(string memory contractName) internal virtual returns (bytes memory code) {
        string memory artifact = string.concat(contractName, ".sol");
        try vm.getCode(artifact) returns (bytes memory code_) {
            if (code_.length != 0) code = code_;
        } catch {}
        if (code.length == 0) {
            console.log("Unable to find contract named '%s'.", contractName);
            revert("Contract does not exist.");
        }
    }

    function setUpContract(
        string memory key,
        string memory contractName,
        bytes memory constructorArgs,
        bool attachOnly
    ) internal virtual returns (address implementation) {
        bytes memory creationCode = abi.encodePacked(getContractCode(contractName), constructorArgs);

        if (UPGRADE_SCRIPTS_BYPASS) return deployCodeWrapper(creationCode);
        if (UPGRADE_SCRIPTS_ATTACH_ONLY) attachOnly = true;

        string memory keyOrContractName = bytes(key).length == 0 ? contractName : key;

        implementation = loadLatestDeployedAddress(keyOrContractName);

        bool deployNew;

        if (implementation != address(0)) {
            if (implementation.code.length == 0) {
                console.log("Stored %s does not contain code.", label(contractName, implementation, key));
                console.log("Make sure '%s' contains all the latest deployments.", getDeploymentsPath("deploy-latest.json")); // prettier-ignore

                revert("Invalid contract address.");
            }

            if (creationCodeHashMatches(implementation, keccak256(creationCode))) {
                console.log("Stored %s up-to-date.", label(contractName, implementation, key));
            } else {
                console.log("Implementation for %s changed.", label(contractName, implementation, key));

                if (attachOnly) console.log("Keeping existing deployment (`attachOnly=true`).");
                else deployNew = true;
            }
        } else {
            console.log("Implementation for %s not found.", label(contractName, implementation, key));
            deployNew = true;

            if (UPGRADE_SCRIPTS_ATTACH_ONLY) revert("Contract deployment is missing.");
        }

        if (deployNew) {
            implementation = confirmDeployCode(creationCode);

            console.log("=> new %s.\n", label(contractName, implementation, key));

            saveCreationCodeHash(implementation, keccak256(creationCode));
        }

        registerContract(keyOrContractName, implementation);
    }

    function setUpContract(
        string memory key,
        string memory contractName,
        bytes memory constructorArgs
    ) internal virtual returns (address implementation) {
        return setUpContract(key, contractName, constructorArgs, false);
    }

    function setUpContract(string memory contractName, bytes memory constructorArgs)
        internal
        virtual
        returns (address implementation)
    {
        return setUpContract("", contractName, constructorArgs, false);
    }

    function setUpContract(string memory contractName) internal virtual returns (address implementation) {
        return setUpContract("", contractName, "", false);
    }

    function setUpProxy(
        string memory key,
        string memory contractName,
        address implementation,
        bytes memory initCall,
        bool attachOnly
    ) internal virtual returns (address proxy) {
        if (UPGRADE_SCRIPTS_BYPASS) {
            assertIsERC1967Upgrade(implementation);

            return deployProxy(implementation, initCall);
        }
        if (UPGRADE_SCRIPTS_ATTACH_ONLY) attachOnly = true;

        string memory keyOrContractName = bytes(key).length == 0 ? string.concat(contractName, "Proxy") : key;

        proxy = loadLatestDeployedAddress(keyOrContractName);

        if (proxy != address(0)) {
            address storedImplementation = loadProxyStoredImplementation(proxy);

            if (storedImplementation != implementation) {
                console.log("Existing %s needs upgrade.", proxyLabel(proxy, contractName, storedImplementation, key)); // prettier-ignore

                if (attachOnly) {
                    console.log("Keeping existing implementation.");
                } else {
                    upgradeSafetyChecks(key, storedImplementation, implementation);

                    console.log("Upgrading %s.\n", proxyLabel(proxy, contractName, implementation, key));

                    requireConfirmation("CONFIRM_UPGRADE");

                    upgradeProxy(proxy, implementation);
                }
            } else {
                console.log("Stored %s up-to-date.", proxyLabel(proxy, contractName, implementation, key));
            }
        } else {
            console.log("Existing %s not found.", proxyLabel(proxy, contractName, implementation, key));

            if (UPGRADE_SCRIPTS_ATTACH_ONLY) revert("Contract deployment is missing.");

            assertIsERC1967Upgrade(implementation);

            proxy = confirmDeployProxy(implementation, initCall);

            console.log("=> new %s.\n", proxyLabel(proxy, contractName, implementation, key));

            generateStorageLayoutFile(contractName, implementation);
        }

        registerContract(keyOrContractName, proxy);
    }

    function setUpProxy(
        string memory key,
        string memory contractName,
        address implementation,
        bytes memory initCall
    ) internal virtual returns (address) {
        return setUpProxy(key, contractName, implementation, initCall, false);
    }

    function setUpProxy(
        string memory key,
        string memory contractName,
        address implementation
    ) internal virtual returns (address) {
        return setUpProxy(key, contractName, implementation, "", false);
    }

    function setUpProxy(string memory contractName, address implementation) internal virtual returns (address) {
        return setUpProxy("", contractName, implementation, "", false);
    }

    function setUpProxy(
        string memory contractName,
        address implementation,
        bytes memory initCall
    ) internal virtual returns (address) {
        return setUpProxy("", contractName, implementation, initCall, false);
    }

    function loadLatestDeployedAddress(string memory key) internal virtual returns (address addr) {
        if (!__latestDeploymentsJsonLoaded) {
            // try reading and caching file containing latest deployments
            try vm.readFile(getDeploymentsPath("deploy-latest.json")) returns (string memory json) {
                __latestDeploymentsJson = json;
            } catch {}
            __latestDeploymentsJsonLoaded = true;
        }

        if (bytes(__latestDeploymentsJson).length == 0) return addr;

        // try vm.parseJson(json, string.concat(".", key)) returns (bytes memory data) {
        try VmParseJson(address(vm)).parseJson(__latestDeploymentsJson, string.concat(".", key)) returns (
            bytes memory data
        ) {
            if (data.length == 32) return abi.decode(data, (address));
        } catch {}
    }

    /* ------------- filePath ------------- */

    function getDeploymentsPath(string memory path) internal virtual returns (string memory) {
        return string.concat("deployments/", vm.toString(block.chainid), "/", path);
    }

    function getDeploymentsDataPath(string memory path) internal virtual returns (string memory) {
        return getDeploymentsPath(string.concat("data/", path));
    }

    function getCreationCodeHashFilePath(address addr) internal virtual returns (string memory) {
        return getDeploymentsDataPath(string.concat(vm.toString(addr), ".creation-code-hash"));
    }

    function getStorageLayoutFilePath(address addr) internal virtual returns (string memory) {
        return getDeploymentsDataPath(string.concat(vm.toString(addr), ".storage-layout"));
    }

    /* ------------- contract registry ------------- */

    function registerContract(string memory name, address addr) internal virtual {
        if (registeredContractAddress[name] != address(0)) {
            console.log("Duplicate entry for key %s (%s) found when registering contract.", name, registeredContractAddress[name]); // prettier-ignore
            revert("Duplicate key.");
        }
        registeredContractName[addr] = name;
        registeredContractAddress[name] = addr;

        registeredContracts.push(ContractData({name: name, addr: addr}));
    }

    function generateRegisteredContractsJson() internal virtual returns (string memory json) {
        if (registeredContracts.length == 0) return "";

        json = "{\n";
        for (uint256 i; i < registeredContracts.length; i++) {
            json = string.concat(
                json,
                '  "',
                registeredContracts[i].name,
                '": "',
                vm.toString(registeredContracts[i].addr),
                i + 1 == registeredContracts.length ? '"\n' : '",\n'
            );
        }
        json = string.concat(json, "}");
    }

    function logDeployments() internal view virtual {
        title("Registered Contracts");

        for (uint256 i; i < registeredContracts.length; i++) {
            console.log("%s=%s", registeredContracts[i].name, registeredContracts[i].addr);
        }
        console.log("");
    }

    function storeLatestDeployments() internal virtual {
        if (!UPGRADE_SCRIPTS_DRY_RUN) {
            string memory json = generateRegisteredContractsJson();

            if (keccak256(bytes(json)) == keccak256(bytes(__latestDeploymentsJson))) {
                console.log("\nNo changes detected.");
            } else {
                vm.writeFile(getDeploymentsPath(string.concat("deploy-latest.json")), json);
                vm.writeFile(getDeploymentsPath(string.concat("deploy-", vm.toString(block.timestamp), ".json")), json);
                console.log("Deployments saved to %s.", getDeploymentsPath(string.concat("deploy-latest.json")));
            }
        }
    }

    /* ------------- snippets ------------- */

    function startBroadcastIfNotDryRun() internal {
        if (!UPGRADE_SCRIPTS_DRY_RUN) {
            vm.startBroadcast();
        } else {
            // console.log('FFI disabled: run again with `--ffi` to save deployments and run storage compatibility checks.'); // prettier-ignore
            console.log("Disabling `vm.broadcast` (dry-run).\n");

            // need to start prank instead now to be consistent in "dry-run"
            vm.stopBroadcast();
            vm.startPrank(tx.origin);
        }
    }

    function generateStorageLayoutFile(string memory contractName, address implementation) internal virtual {
        if (storageLayoutGenerated[implementation]) return;

        if (!isFFIEnabled()) {
            return console.log("SKIPPING storage layout mapping for %s (`FFI=false`).\n", label(contractName, implementation, '')); // prettier-ignore
        }

        console.log("Generating storage layout mapping for %s.\n", label(contractName, implementation, ""));

        // assert Contract exists
        getContractCode(contractName);

        string[] memory script = new string[](4);
        script[0] = "forge";
        script[1] = "inspect";
        script[2] = contractName;
        script[3] = "storage-layout";

        bytes memory out = vm.ffi(script);

        vm.writeFile(getStorageLayoutFilePath(implementation), string(out));

        storageLayoutGenerated[implementation] = true;
    }

    function assertFileExists(string memory file) internal virtual {
        string[] memory script = new string[](2);
        script[0] = "ls";
        script[1] = file;

        bool exists;
        try vm.ffi(script) returns (bytes memory res) {
            if (bytes(res).length != 0) {
                exists = true;
                console.log("assertFileExists got", string(res));
            }
        } catch {}

        if (!exists) {
            console.log("Unable to locate file '%s'.", file);
            revert("File does not exist.");
        }
    }

    function upgradeSafetyChecks(
        string memory contractName,
        address oldImplementation,
        address newImplementation
    ) internal virtual {
        if (isUpgradeSafe[oldImplementation][newImplementation]) {
            return console.log("Storage layout compatibility check [%s <-> %s]: pass (`isUpgradeSafe=true`)", oldImplementation, newImplementation); // prettier-ignore
        }
        if (!isFFIEnabled()) {
            return console.log("SKIPPING storage layout compatibility check [%s <-> %s] (`FFI=false`).", oldImplementation, newImplementation); // prettier-ignore
        }

        generateStorageLayoutFile(contractName, newImplementation);

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
            console.log("Storage layout compatibility check [%s <-> %s]: pass.", oldImplementation, newImplementation);
        } else {
            console.log("Storage layout compatibility check [%s <-> %s]: fail", oldImplementation, newImplementation);
            console.log("\nDiff:");
            console.log(string(diff));

            console.log("\nIf you believe the storage layout is compatible, add");
            console.log("`if (block.chainid == %s) isUpgradeSafe[%s][%s] = true;` to the beginning of `run()` in your deploy script.", block.chainid, oldImplementation, newImplementation); // prettier-ignore

            revert("Contract storage layout changed and might not be compatible.");
        }

        isUpgradeSafe[oldImplementation][newImplementation] = true;
    }

    function saveCreationCodeHash(address addr, bytes32 creationCodeHash) internal virtual {
        if (UPGRADE_SCRIPTS_DRY_RUN) return;

        string memory path = getCreationCodeHashFilePath(addr);

        // console.log(string.concat("Saving creation code hash for ", vm.toString(addr), "."));

        vm.writeFile(path, vm.toString(creationCodeHash));
    }

    // .codehash is an improper check for contracts that use immutables
    function creationCodeHashMatches(address addr, bytes32 newCreationCodeHash) internal virtual returns (bool) {
        string memory path = getCreationCodeHashFilePath(addr);

        try vm.readFile(path) returns (string memory data) {
            bytes32 codehash = parseBytes32(data);

            if (codehash == newCreationCodeHash) {
                // console.log(string.concat("Found matching codehash (", vm.toString(codehash), ") for"), addr);

                return true;
            } else {
                // console.log(string.concat("Existing codehash (", vm.toString(codehash), "), does not match new codehash (", vm.toString(newCreationCodeHash), ") for"), addr); // prettier-ignore
            }
        } catch {
            // console.log("Could not find existing codehash for", addr);
        }
        return false;
    }

    function mkdir(string memory path) internal virtual {
        string[] memory script = new string[](3);
        script[0] = "mkdir";
        script[1] = "-p";
        script[2] = path;

        vm.ffi(script);
    }

    /* ------------- utils ------------- */

    /// @dev code for constructing ERC1967Proxy(address implementation, bytes memory initCall)
    /// makes an initial delegatecall to `implementation` with calldata `initCall` (if `initCall` != "")
    function getDeployProxyCode(address implementation, bytes memory initCall)
        internal
        pure
        virtual
        returns (bytes memory)
    {
        return abi.encodePacked(type(ERC1967Proxy).creationCode, abi.encode(implementation, initCall));
    }

    function upgradeProxy(address proxy, address newImplementation) internal virtual {
        UUPSUpgrade(proxy).upgradeToAndCall(newImplementation, "");
    }

    function deployCode(bytes memory code) internal virtual returns (address addr) {
        assembly {
            addr := create(0, add(code, 0x20), mload(code))
        }
    }

    function deployCodeWrapper(bytes memory code) internal virtual returns (address addr) {
        addr = deployCode(code);

        firstTimeDeployed[addr] = true;

        require(addr.code.length != 0, "Failed to deploy code.");
    }

    function deployProxy(address implementation, bytes memory initCall) internal virtual returns (address) {
        return deployCodeWrapper(getDeployProxyCode(implementation, initCall));
    }

    function confirmDeployProxy(address implementation, bytes memory initCall) internal virtual returns (address) {
        return confirmDeployCode(getDeployProxyCode(implementation, initCall));
    }

    function confirmDeployCode(bytes memory code) internal virtual returns (address) {
        requireConfirmation("CONFIRM_DEPLOYMENT");

        return deployCodeWrapper(code);
    }

    function requireConfirmation(string memory variable) internal virtual {
        if (isTestnet() || UPGRADE_SCRIPTS_DRY_RUN) return;

        bool confirmed;
        try vm.envBool(variable) returns (bool confirmed_) {
            confirmed = confirmed_;
        } catch {}

        if (!confirmed) {
            console.log("\nWARNING: `%s=true` must be set for mainnet.", variable);

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

    function hasCode(address addr) internal view virtual returns (bool hasCode_) {
        assembly {
            hasCode_ := iszero(iszero(extcodesize(addr)))
        }
    }

    function isTestnet() internal view virtual returns (bool) {
        if (block.chainid == 4) return true; // Rinkeby
        if (block.chainid == 5) return true; // Goerli
        if (block.chainid == 420) return true; // Optimism
        if (block.chainid == 3_1337) return true; // Anvil
        if (block.chainid == 80_001) return true; // Mumbai
        if (block.chainid == 421_611) return true; // Arbitrum
        if (block.chainid == 111_55_111) return true; // Sepolia
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

    function assertIsERC1967Upgrade(address implementation) internal virtual {
        if (implementation.code.length == 0) {
            console.log("No code stored at %s.", implementation);
            revert("Invalid contract address.");
        }
        try UUPSUpgrade(implementation).proxiableUUID() returns (bytes32 uuid) {
            if (uuid != ERC1967_PROXY_STORAGE_SLOT) {
                console.log("Invalid proxiable UUID for implementation %s.", implementation);
                revert("Contract not upgradeable.");
            }
        } catch {
            console.log("Contract %s does not implement proxiableUUID().", implementation);
            revert("Contract not upgradeable.");
        }
    }

    function loadProxyStoredImplementation(address proxy) internal virtual returns (address implementation) {
        require(proxy.code.length != 0, string.concat("No code stored at ", vm.toString(proxy)));

        try vm.load(proxy, ERC1967_PROXY_STORAGE_SLOT) returns (bytes32 data) {
            implementation = address(uint160(uint256(data)));
            require(
                implementation != address(0),
                string.concat("Invalid existing implementation address (0) for proxy ", vm.toString(proxy))
            );
            require(
                UUPSUpgrade(implementation).proxiableUUID() == ERC1967_PROXY_STORAGE_SLOT,
                string.concat("Invalid proxiable UUID for implementation ", vm.toString(implementation))
            );
        } catch {
            console.log("Contract %s not identified as a proxy", proxy);
        }
    }

    // hacky until vm.parseBytes32 comes around
    function parseBytes32(string memory data) internal virtual returns (bytes32) {
        vm.setEnv("_TMP", data);
        return vm.envBytes32("_TMP");
    }

    /* ------------- prints ------------- */

    function title(string memory name) internal view virtual {
        console.log("\n==========================");
        console.log("%s:\n", name);
    }

    function label(
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
                    : string.concat("(", vm.toString(proxy), " -> ", vm.toString(implementation), ")"),
                bytes(key).length == 0 ? "" : string.concat(" [", key, "]")
            );
    }
}
