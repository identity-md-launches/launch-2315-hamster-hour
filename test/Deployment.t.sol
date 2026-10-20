// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {AntiSniperHook} from "../src/AntiSniperHook.sol";
import {HamsterHourToken} from "../src/HamsterHourToken.sol";
import {DeploymentConfig} from "../src/DeploymentConfig.sol";
import {HookFlags} from "../src/HookFlags.sol";
import {HookSalt} from "../src/libraries/HookSalt.sol";
import {PrepareDeployment} from "../script/PrepareDeployment.s.sol";

contract DeploymentTest is Test {
    function test_preparedBytecodeDeploysWithoutCallingExternalContracts() public {
        // Empty-chain probes are test fixtures, not production configuration.
        IPoolManager manager = IPoolManager(makeAddr("manager-probe"));
        address token = makeAddr("token-probe");
        PrepareDeployment preparation = new PrepareDeployment();
        (bytes memory args, bytes32 salt, address predicted) =
            preparation.run(address(this), manager, token, 0, 200_000);
        bytes memory initCode = abi.encodePacked(type(AntiSniperHook).creationCode, args);
        assertEq(HookSalt.predict(address(this), salt, keccak256(initCode)), predicted);
        assertTrue(HookFlags.matches(predicted, HookFlags.REQUIRED));
        address at;
        assembly ("memory-safe") {
            at := create2(0, add(initCode, 32), mload(initCode), salt)
        }
        assertEq(at, predicted);
        assertGt(at.code.length, 0);
        assertEq(address(AntiSniperHook(at).poolManager()), address(manager));
        assertEq(AntiSniperHook(at).hamster(), token);
        assertEq(AntiSniperHook(at).poolInitialisedAt(), block.timestamp);
        _scan(at);
        _scan(address(new HamsterHourToken()));
    }

    function test_wrongHookAddressBitsRejectDeployment() public {
        // Constructor runs in place at an address with no permissions.
        address at = address(uint160(1 << 20));
        bytes memory code = abi.encodePacked(
            type(AntiSniperHook).creationCode,
            abi.encode(
                IPoolManager(makeAddr("manager")),
                makeAddr("token"),
                uint256(3000),
                uint256(500),
                uint256(600),
                DeploymentConfig.FEE_RECIPIENT
            )
        );
        vm.etch(at, code);
        (bool ok, bytes memory reason) = at.call("");
        assertFalse(ok);
        assertEq(bytes4(reason), Hooks.HookAddressNotValid.selector);
    }

    function test_preparationRejectsMissingAddresses() public {
        PrepareDeployment preparation = new PrepareDeployment();
        vm.expectRevert("zero deployment input");
        preparation.run(address(0), IPoolManager(makeAddr("manager")), makeAddr("token"), 0, 1);
    }

    function test_saltSearchIsBoundedAndResumable() public view {
        bytes32 hash = keccak256("test-creation-code");
        (address predicted, bytes32 salt) = HookSalt.find(address(this), hash, 1_000, 200_000);
        assertTrue(HookFlags.matches(predicted, HookFlags.REQUIRED));
        (address again, bytes32 same) = HookSalt.find(address(this), hash, uint256(salt), 1);
        assertEq(again, predicted);
        assertEq(same, salt);
    }

    function _scan(address target) internal view {
        bytes memory code = target.code;
        assertLe(code.length, 24_576);
        for (uint256 i; i < code.length; ++i) {
            uint8 op = uint8(code[i]);
            if (op >= 0x60 && op <= 0x7f) {
                i += op - 0x5f;
            } else {
                assertTrue(op != 0xff && op != 0xf4 && op != 0xf2, "forbidden runtime opcode");
            }
        }
    }
}
