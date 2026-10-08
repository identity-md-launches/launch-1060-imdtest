// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {FullMath} from "v4-core/src/libraries/FullMath.sol";
import {IMDTToken} from "../src/IMDTToken.sol";
import {V4Actor, PairFixture} from "./helpers/V4Actors.sol";

contract LaunchFlowTest is Test {
    using StateLibrary for IPoolManager;

    uint256 private constant SUPPLY = 1_000_000_000e18;
    uint256 private constant SWARM = SUPPLY / 10;
    uint256 private constant POOL_BUDGET = SUPPLY * 9000 / 10_000;
    address private constant MANAGER = 0x000000000004444c5dc75cB358380D2e3dE08A90;
    address private constant IMD = 0xD34a99Bc0f67aE1bbd63C660e6d0b0dd03E263B7;
    address private constant REMAINDER = 0x000000000000000000000000000000000000dEaD;

    IPoolManager private manager;
    PairFixture private pair;
    V4Actor private factory;
    V4Actor private trader;
    address private distributor;
    address private claimant;

    function setUp() public {
        vm.chainId(1);
        // Execute the constructor in place, preserving PoolManager's NoDelegateCall immutable.
        vm.etch(MANAGER, abi.encodePacked(type(PoolManager).creationCode, abi.encode(address(this))));
        (bool ok, bytes memory runtime) = MANAGER.call("");
        require(ok && runtime.length > 0, "local manager construction failed");
        vm.etch(MANAGER, runtime);
        manager = IPoolManager(MANAGER);
        vm.etch(IMD, address(new PairFixture()).code);
        pair = PairFixture(IMD);
        factory = new V4Actor(manager);
        trader = new V4Actor(manager);
        distributor = makeAddr("external Merkle distributor fixture");
        claimant = makeAddr("swarm claimant");
    }

    function test_SeedAndSwapsWhenTokenIsCurrency0() public {
        _launchAndTrade(true);
    }

    function test_SeedAndSwapsWhenTokenIsCurrency1() public {
        _launchAndTrade(false);
    }

    function test_UnauthorizedCallbackRejected() public {
        vm.expectRevert("pool manager only");
        factory.unlockCallback("");
    }

    function test_UnsettledSwapRevertsAtomically() public {
        (IMDTToken token, PoolKey memory key) = _seed(true);
        uint256 managerBalance = token.balanceOf(MANAGER);
        (uint160 priceBefore,,,) = manager.getSlot0(key.toId());
        // The trader has no IMD. Its settlement transfer must revert and roll back the swap.
        vm.expectRevert();
        trader.swap(key, false, 0.01 ether);
        (uint160 priceAfter,,,) = manager.getSlot0(key.toId());
        assertEq(priceAfter, priceBefore);
        assertEq(token.balanceOf(MANAGER), managerBalance);
        assertEq(token.balanceOf(address(trader)), 0);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_PoolFeeCannotBeDynamicallyChanged() public {
        (, PoolKey memory key) = _seed(true);
        vm.expectRevert(IPoolManager.UnauthorizedDynamicLPFeeUpdate.selector);
        manager.updateDynamicLPFee(key, 12_500);
        (,,, uint24 fee) = manager.getSlot0(key.toId());
        assertEq(fee, 3000);
    }

    function test_SwapRequiresUnlock() public {
        (, PoolKey memory key) = _seed(true);
        vm.expectRevert(IPoolManager.ManagerLocked.selector);
        manager.swap(key, SwapParams(false, -int256(0.01 ether), TickMath.MAX_SQRT_PRICE - 1), "");
    }

    function _launchAndTrade(bool tokenIsZero) private {
        (IMDTToken token, PoolKey memory key) = _seed(tokenIsZero);
        uint256 seeded = token.balanceOf(MANAGER);
        pair.mint(address(trader), 1 ether);
        BalanceDelta boughtDelta = trader.swap(key, !tokenIsZero, 0.01 ether);
        uint256 bought = token.balanceOf(address(trader));
        assertGt(bought, 0);
        assertEq(bought, uint256(int256(tokenIsZero ? boughtDelta.amount0() : boughtDelta.amount1())));
        assertEq(token.balanceOf(MANAGER), seeded - bought);
        assertEq(pair.balanceOf(address(trader)), 0.99 ether);
        assertEq(pair.balanceOf(MANAGER), 0.01 ether);

        BalanceDelta soldDelta = trader.swap(key, tokenIsZero, bought);
        assertEq(uint256(-int256(tokenIsZero ? soldDelta.amount0() : soldDelta.amount1())), bought);
        assertEq(token.balanceOf(address(trader)), 0);
        assertEq(token.balanceOf(MANAGER), seeded);
        assertGt(pair.balanceOf(address(trader)), 0.99 ether);
        assertLt(pair.balanceOf(address(trader)), 1 ether); // AMM fee, never an IMDT transfer tax.
        assertEq(pair.balanceOf(address(trader)) + pair.balanceOf(MANAGER), 1 ether);
        assertEq(token.balanceOf(claimant), SWARM);
        assertEq(token.balanceOf(MANAGER) + token.balanceOf(claimant) + token.balanceOf(REMAINDER), SUPPLY);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function _seed(bool tokenIsZero) private returns (IMDTToken token, PoolKey memory key) {
        token = _deployInOrder(tokenIsZero);
        assertEq(token.balanceOf(address(factory)), SUPPLY);
        assertEq(token.balanceOf(distributor), 0);
        assertEq(token.balanceOf(address(token)), 0);
        factory.move(token, distributor, SWARM);
        assertEq(token.balanceOf(distributor), SWARM);
        // Claims are external to the token. This models the exact transfer, not Merkle verification.
        vm.prank(distributor);
        assertTrue(token.transfer(claimant, SWARM));
        assertEq(token.balanceOf(claimant), SWARM);
        assertEq(token.balanceOf(distributor), 0);

        key = PoolKey({
            currency0: Currency.wrap(tokenIsZero ? address(token) : IMD),
            currency1: Currency.wrap(tokenIsZero ? IMD : address(token)),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(0))
        });
        // sqrt(cap / totalSupply) * 2^96 for token0; the reciprocal for token1.
        // These exact integer roots derive from cap = 2500e18 and supply = 1e27.
        uint160 price = tokenIsZero ? 125_270_724_187_523_965_593_206_900 : 50_108_289_675_009_586_237_282_760_313_921;
        int24 tick = manager.initialize(key, price);
        (uint160 actualPrice,, uint24 protocolFee, uint24 lpFee) = manager.getSlot0(key.toId());
        assertEq(actualPrice, price);
        assertEq(lpFee, 3000);
        assertEq(protocolFee, 0);
        assertEq(Currency.unwrap(tokenIsZero ? key.currency1 : key.currency0), IMD);

        // Place liquidity wholly on the IMDT side, immediately beyond the current tick.
        int24 floor = tick / 60 * 60;
        if (tick < 0 && tick % 60 != 0) floor -= 60;
        int24 lower = tokenIsZero ? floor + 60 : -887_220;
        int24 upper = tokenIsZero ? int24(887_220) : floor;
        uint160 sqrtA = TickMath.getSqrtPriceAtTick(lower);
        uint160 sqrtB = TickMath.getSqrtPriceAtTick(upper);
        uint256 liquidity = tokenIsZero
            ? FullMath.mulDiv(POOL_BUDGET, FullMath.mulDiv(sqrtA, sqrtB, 1 << 96), sqrtB - sqrtA)
            : FullMath.mulDiv(POOL_BUDGET, 1 << 96, sqrtB - sqrtA);
        assertLe(liquidity, type(uint128).max);
        BalanceDelta seedDelta = factory.seed(key, lower, upper, uint128(liquidity));
        uint256 seeded = uint256(-int256(tokenIsZero ? seedDelta.amount0() : seedDelta.amount1()));
        assertEq(tokenIsZero ? seedDelta.amount1() : seedDelta.amount0(), 0);
        assertGt(seeded, POOL_BUDGET * 9999 / 10_000);
        assertLe(seeded, POOL_BUDGET);
        assertEq(token.balanceOf(MANAGER), seeded);
        assertEq(pair.balanceOf(MANAGER), 0);

        uint256 remainder = token.balanceOf(address(factory));
        assertEq(remainder, POOL_BUDGET - seeded);
        factory.move(token, REMAINDER, remainder);
        assertEq(token.balanceOf(address(factory)), 0);
        assertEq(token.balanceOf(REMAINDER), remainder);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function _deployInOrder(bool tokenIsZero) private returns (IMDTToken) {
        bytes32 initHash = keccak256(type(IMDTToken).creationCode);
        for (uint256 i; i < 1000; ++i) {
            bytes32 salt = bytes32(i);
            address predicted =
                address(uint160(uint256(keccak256(abi.encodePacked(hex"ff", address(factory), salt, initHash)))));
            if (predicted != IMD && (predicted < IMD) == tokenIsZero) {
                IMDTToken token = factory.deploy(salt);
                assertEq(address(token), predicted);
                return token;
            }
        }
        revert("test salt search exhausted");
    }
}
