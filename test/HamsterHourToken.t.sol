// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {HamsterHourToken} from "../src/HamsterHourToken.sol";
import {DeploymentConfig} from "../src/DeploymentConfig.sol";

contract HamsterHourTokenTest is Test {
    HamsterHourToken internal token;
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");

    function setUp() public {
        token = new HamsterHourToken();
    }

    function test_metadataAndEntireSupplyToConstructorCaller() public view {
        assertEq(token.name(), "Hamster Hour");
        assertEq(token.symbol(), "HAMSTER");
        assertEq(token.decimals(), 18);
        assertEq(token.totalSupply(), 1_000_000_000 ether);
        assertEq(token.balanceOf(address(this)), token.totalSupply());
    }

    function testFuzz_transferNeverTaxed(uint256 amount, uint64 elapsed) public {
        amount = bound(amount, 0, token.totalSupply());
        vm.warp(uint256(elapsed));
        uint256 before = token.balanceOf(address(this));
        assertTrue(token.transfer(alice, amount));
        assertEq(token.balanceOf(alice), amount);
        assertEq(token.balanceOf(address(this)), before - amount);
        assertEq(token.balanceOf(DeploymentConfig.FEE_RECIPIENT), 0);
        assertEq(token.totalSupply(), 1_000_000_000 ether);
    }

    function test_transferFromMovesFullAmountAndSpendsAllowance() public {
        token.transfer(alice, 10 ether);
        vm.prank(alice);
        token.approve(bob, 7 ether);
        vm.prank(bob);
        token.transferFrom(alice, bob, 7 ether);
        assertEq(token.balanceOf(alice), 3 ether);
        assertEq(token.balanceOf(bob), 7 ether);
        assertEq(token.allowance(alice, bob), 0);
    }

    function test_transferWithoutBalanceOrAllowanceFailsAtomically() public {
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, alice, 0, 1));
        vm.prank(alice);
        token.transfer(bob, 1);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, bob, 0, 1));
        vm.prank(bob);
        token.transferFrom(address(this), bob, 1);
        assertEq(token.balanceOf(address(this)), token.totalSupply());
    }

    function test_zeroRecipientRejectedAndSelfTransferConservesBalance() public {
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        token.transfer(address(0), 1);
        token.transfer(address(this), token.totalSupply());
        assertEq(token.balanceOf(address(this)), token.totalSupply());
    }

    function test_noPrivilegedSelectorsEvenForDeployer() public {
        string[11] memory calls = [
            "owner()",
            "mint(address,uint256)",
            "burn(uint256)",
            "pause()",
            "unpause()",
            "blacklist(address)",
            "setFee(uint256)",
            "transferOwnership(address)",
            "upgradeTo(address)",
            "initialize(address)",
            "setMinter(address)"
        ];
        for (uint256 i; i < calls.length; ++i) {
            (bool ok,) = address(token).call(abi.encodeWithSignature(calls[i], alice, 1 ether));
            assertFalse(ok, calls[i]);
        }
        assertEq(token.totalSupply(), 1_000_000_000 ether);
    }
}
