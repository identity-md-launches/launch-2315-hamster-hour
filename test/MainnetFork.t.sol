// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {ModifyLiquidityParams} from "v4-core/src/types/PoolOperation.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {HamsterHourToken} from "../src/HamsterHourToken.sol";
import {DeploymentConfig} from "../src/DeploymentConfig.sol";
import {HookBehavior} from "./helpers/HookBehavior.sol";
import {HookFixture} from "./helpers/HookFixture.sol";

/// @notice Runs the economic suite against the real Ethereum PoolManager and real IMD.
/// @dev Invoke with forge test --fork-url <mainnet RPC> --match-contract MainnetForkTest.
///      No environment variables, replacement runtime code, or mocked manager in this suite.
contract MainnetForkTest is HookBehavior {
    // Test-only reference from https://developers.uniswap.org/docs/protocols/v4/deployments.
    // Production constructor and preparation script always take manager as an argument.
    IPoolManager internal constant MAINNET_MANAGER = IPoolManager(0x000000000004444c5dc75cB358380D2e3dE08A90);

    function setUp() public {
        try vm.activeFork() returns (uint256) {}
        catch {
            vm.skip(true, "requires --fork-url pointing to Ethereum mainnet");
            return;
        }
        assertEq(block.chainid, 1, "fork must be Ethereum mainnet");
        assertGt(address(MAINNET_MANAGER).code.length, 0);
        assertGt(DeploymentConfig.IMD.code.length, 0);
        assertEq(IERC20Metadata(DeploymentConfig.IMD).symbol(), "IMD");
        assertEq(IERC20Metadata(DeploymentConfig.IMD).decimals(), 18);
        manager = MAINNET_MANAGER;
        hamster = new HamsterHourToken();
        imd = IERC20(DeploymentConfig.IMD);
        // Only test-wallet balances are provisioned. Real IMD transfer logic remains untouched.
        deal(DeploymentConfig.IMD, address(this), 2_000_000 ether);
        _createPool();
        _seed();
    }
}

/// @notice Also rehearses the launch's 2,500 IMD opening capitalization, instead of the unit-test 1:1 price.
contract MainnetLaunchPriceTest is HookFixture {
    using StateLibrary for IPoolManager;

    function test_launchPriceBuyAndSellOnMainnet() public {
        try vm.activeFork() returns (uint256) {}
        catch {
            vm.skip(true, "requires --fork-url pointing to Ethereum mainnet");
            return;
        }
        assertEq(block.chainid, 1);
        manager = IPoolManager(0x000000000004444c5dc75cB358380D2e3dE08A90);
        assertGt(address(manager).code.length, 0);
        imd = IERC20(DeploymentConfig.IMD);
        hamster = new HamsterHourToken();
        deal(DeploymentConfig.IMD, address(this), 10_000 ether);
        bool hamsterIs0 = address(hamster) < DeploymentConfig.IMD;
        uint256 ratioX192 =
            hamsterIs0 ? uint256(2500) * (1 << 192) / 1_000_000_000 : uint256(1_000_000_000) * (1 << 192) / 2500;
        uint160 price = uint160(Math.sqrt(ratioX192));
        _createPoolAtPrice(price);
        driver.modify(
            key,
            ModifyLiquidityParams(-887220, 887220, int256(LIQUIDITY), bytes32(0)),
            hamsterIs0 ? 700_000_000 ether : 2500 ether,
            hamsterIs0 ? 2500 ether : 700_000_000 ether
        );
        (uint160 actual,,,) = manager.getSlot0(key.toId());
        assertEq(actual, price);
        uint256 feeBefore = imd.balanceOf(DeploymentConfig.FEE_RECIPIENT);
        BalanceDelta bought = _swap(true, -int256(10 ether), 10 ether, true);
        assertEq(_input(bought, true), 10 ether);
        assertGt(_output(bought, true), 1_000_000 ether);
        assertEq(imd.balanceOf(DeploymentConfig.FEE_RECIPIENT) - feeBefore, 3 ether);
        uint256 fees = imd.balanceOf(DeploymentConfig.FEE_RECIPIENT);
        BalanceDelta sold = _swap(false, -int256(1_000_000 ether), 1_000_000 ether, false);
        assertEq(_input(sold, false), 1_000_000 ether);
        assertGt(_output(sold, false), 0);
        assertEq(imd.balanceOf(DeploymentConfig.FEE_RECIPIENT), fees);
        assertEq(imd.balanceOf(address(hook)), 0);
        assertEq(hamster.balanceOf(address(hook)), 0);
    }
}
