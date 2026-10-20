// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @notice Fixed launch economics. Libraries are inlined, not separately deployed.
library DeploymentConfig {
    uint256 internal constant CHAIN_ID = 1;
    uint256 internal constant SUPPLY = 1_000_000_000 ether;
    uint256 internal constant BPS = 10_000;
    uint256 internal constant START_BPS = 3000;
    uint256 internal constant FLOOR_BPS = 500;
    uint256 internal constant DECAY_SECONDS = 600;
    address internal constant FEE_RECIPIENT = 0xBB85C1b7540d9e7b56F7a595FC1ff7Dd07Cb0823;
    address internal constant IMD = 0xD34a99Bc0f67aE1bbd63C660e6d0b0dd03E263B7;
    uint24 internal constant POOL_FEE = 12_500;
    int24 internal constant TICK_SPACING = 60;
}
