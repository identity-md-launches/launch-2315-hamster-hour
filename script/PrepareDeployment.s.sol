// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {AntiSniperHook} from "../src/AntiSniperHook.sol";
import {DeploymentConfig} from "../src/DeploymentConfig.sol";
import {HookSalt} from "../src/libraries/HookSalt.sol";

/// @notice Non-broadcasting constructor-data and CREATE2 salt preparation.
/// @dev All deployment-specific addresses are explicit inputs. Does not deploy or open the pool.
contract PrepareDeployment {
    function run(address factory, IPoolManager manager, address token, uint256 start, uint256 attempts)
        external
        pure
        returns (bytes memory constructorArgs, bytes32 salt, address predicted)
    {
        require(factory != address(0) && address(manager) != address(0) && token != address(0), "zero deployment input");
        constructorArgs = abi.encode(
            manager,
            token,
            DeploymentConfig.START_BPS,
            DeploymentConfig.FLOOR_BPS,
            DeploymentConfig.DECAY_SECONDS,
            DeploymentConfig.FEE_RECIPIENT
        );
        bytes32 initCodeHash = keccak256(abi.encodePacked(type(AntiSniperHook).creationCode, constructorArgs));
        (predicted, salt) = HookSalt.find(factory, initCodeHash, start, attempts);
    }
}
