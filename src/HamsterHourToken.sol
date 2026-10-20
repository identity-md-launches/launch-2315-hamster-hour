// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {DeploymentConfig} from "./DeploymentConfig.sol";

/// @notice Fixed supply, ordinary ERC-20. No privileged or post-construction mint/burn entry points.
contract HamsterHourToken is ERC20 {
    constructor() ERC20("Hamster Hour", "HAMSTER") {
        _mint(msg.sender, DeploymentConfig.SUPPLY);
    }
}
