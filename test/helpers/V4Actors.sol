// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {ModifyLiquidityParams, SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {IMDTToken} from "../../src/IMDTToken.sol";

/// @dev Test-only pair balance fixture; does not represent live IMD behavior or storage.
contract PairFixture is ERC20 {
    constructor() ERC20("Test pair", "PAIR") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// @dev Test-only factory/trader driver. Not a launch factory or production router.
contract V4Actor is IUnlockCallback {
    IPoolManager private immutable manager;
    address private immutable controller = msg.sender;

    modifier onlyController() {
        require(msg.sender == controller, "test controller only");
        _;
    }

    constructor(IPoolManager manager_) {
        manager = manager_;
    }

    function deploy(bytes32 salt) external onlyController returns (IMDTToken) {
        return new IMDTToken{salt: salt}();
    }

    function move(IERC20 token, address to, uint256 amount) external onlyController {
        require(token.transfer(to, amount), "transfer failed");
    }

    function seed(PoolKey memory key, int24 lower, int24 upper, uint128 liquidity)
        external
        onlyController
        returns (BalanceDelta)
    {
        return abi.decode(
            manager.unlock(abi.encode(uint8(0), key, abi.encode(lower, upper, liquidity))), (BalanceDelta)
        );
    }

    function swap(PoolKey memory key, bool zeroForOne, uint256 amount) external onlyController returns (BalanceDelta) {
        return abi.decode(manager.unlock(abi.encode(uint8(1), key, abi.encode(zeroForOne, amount))), (BalanceDelta));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(manager), "pool manager only");
        (uint8 operation, PoolKey memory key, bytes memory params) = abi.decode(data, (uint8, PoolKey, bytes));
        BalanceDelta delta;
        if (operation == 0) {
            (int24 lower, int24 upper, uint128 liquidity) = abi.decode(params, (int24, int24, uint128));
            (delta,) = manager.modifyLiquidity(
                key, ModifyLiquidityParams(lower, upper, int256(uint256(liquidity)), bytes32(0)), ""
            );
        } else {
            (bool zeroForOne, uint256 amount) = abi.decode(params, (bool, uint256));
            require(amount <= uint256(type(int256).max), "amount too large");
            delta = manager.swap(
                key,
                SwapParams(
                    zeroForOne, -int256(amount), zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
                ),
                ""
            );
        }
        _settle(key.currency0, delta.amount0());
        _settle(key.currency1, delta.amount1());
        return abi.encode(delta);
    }

    function _settle(Currency currency, int128 delta) private {
        if (delta < 0) {
            uint256 amount = uint256(-int256(delta));
            manager.sync(currency);
            require(IERC20(Currency.unwrap(currency)).transfer(address(manager), amount), "settlement failed");
            require(manager.settle() == amount, "short settlement");
        } else if (delta > 0) {
            manager.take(currency, address(this), uint256(int256(delta)));
        }
    }
}
