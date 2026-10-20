// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {HookFlags} from "../HookFlags.sol";

/// @notice Off-chain preparation helper. All functions are internal; no deployed library is needed.
library HookSalt {
    error SaltNotFound();

    function predict(address deployer, bytes32 salt, bytes32 initCodeHash) internal pure returns (address) {
        return address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), deployer, salt, initCodeHash)))));
    }

    function find(address deployer, bytes32 initCodeHash, uint256 start, uint256 attempts)
        internal
        pure
        returns (address predicted, bytes32 salt)
    {
        for (uint256 i; i < attempts; ++i) {
            salt = bytes32(start + i);
            predicted = predict(deployer, salt, initCodeHash);
            if (HookFlags.matches(predicted, HookFlags.REQUIRED)) return (predicted, salt);
        }
        revert SaltNotFound();
    }
}
