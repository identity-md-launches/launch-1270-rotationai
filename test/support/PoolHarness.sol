// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {RAIToken} from "../../src/RAIToken.sol";
import {RAITestBase} from "./RAITestBase.sol";
import {PoolManager} from "../vendor/v4-core/src/PoolManager.sol";
import {IPoolManager} from "../vendor/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "../vendor/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {IHooks} from "../vendor/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "../vendor/v4-core/src/types/PoolKey.sol";
import {Currency} from "../vendor/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "../vendor/v4-core/src/types/BalanceDelta.sol";
import {TickMath} from "../vendor/v4-core/src/libraries/TickMath.sol";
import {FullMath} from "../vendor/v4-core/src/libraries/FullMath.sol";
import {StateLibrary} from "../vendor/v4-core/src/libraries/StateLibrary.sol";
import {TransientStateLibrary} from "../vendor/v4-core/src/libraries/TransientStateLibrary.sol";

/// @dev Test-only settlement helper. Always observes the manager's actual balance difference.
abstract contract PoolSettler is IUnlockCallback {
    IPoolManager public immutable manager;

    constructor(IPoolManager manager_) {
        manager = manager_;
    }

    receive() external payable {}

    function _settle(Currency currency, int128 delta, uint256 shortfall) internal {
        if (delta > 0) {
            manager.take(currency, address(this), uint128(delta));
        } else if (delta < 0) {
            uint256 owed = uint256(-int256(delta));
            uint256 payment = owed - shortfall;
            manager.sync(currency);
            uint256 paid;
            if (Currency.unwrap(currency) == address(0)) {
                paid = manager.settle{value: payment}();
            } else {
                require(RAIToken(Currency.unwrap(currency)).transfer(address(manager), payment), "payment failed");
                paid = manager.settle();
            }
            require(paid == payment, "PoolManager settlement arrived short");
        }
    }
}

/// @dev Models just the launch's token movements, not a Merkle tree or the production factory.
contract PoolLaunchHarness is PoolSettler {
    RAIToken public immutable token;
    PoolKey internal key;
    int24 public tickLower;
    int24 public tickUpper;
    uint128 public liquidity;
    bool private seeded;

    constructor(IPoolManager manager_) PoolSettler(manager_) {
        token = new RAIToken();
    }

    function seed(PoolKey memory key_, address distributor, address remainderTo, uint160 openingPrice)
        external
        returns (BalanceDelta delta)
    {
        require(!seeded, "already seeded");
        seeded = true;
        key = key_;
        // The constructor left all 1e27 units here. The factory moves the swarm allocation first.
        require(token.transfer(distributor, 100_000_000e18), "swarm transfer failed");
        int24 tick = manager.initialize(key_, openingPrice);
        // Native ETH is currency0. A range below the opening price holds only RAI (currency1).
        tickUpper = (tick / key_.tickSpacing) * key_.tickSpacing;
        tickLower = tickUpper - 12_000;
        uint160 sqrtLower = TickMath.getSqrtPriceAtTick(tickLower);
        uint160 sqrtUpper = TickMath.getSqrtPriceAtTick(tickUpper);
        liquidity = uint128(FullMath.mulDiv(900_000_000e18, 1 << 96, sqrtUpper - sqrtLower));
        delta = abi.decode(manager.unlock(abi.encode(int256(uint256(liquidity)))), (BalanceDelta));
        require(token.transfer(remainderTo, token.balanceOf(address(this))), "rounding remainder failed");
    }

    function collectFees() external returns (BalanceDelta) {
        return abi.decode(manager.unlock(abi.encode(int256(0))), (BalanceDelta));
    }

    function removeLiquidity() external returns (BalanceDelta) {
        uint128 removed = liquidity;
        liquidity = 0;
        return abi.decode(manager.unlock(abi.encode(-int256(uint256(removed)))), (BalanceDelta));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(manager), "not manager");
        int256 change = abi.decode(data, (int256));
        (BalanceDelta delta,) = manager.modifyLiquidity(
            key, IPoolManager.ModifyLiquidityParams(tickLower, tickUpper, change, bytes32(0)), ""
        );
        _settle(key.currency0, delta.amount0(), 0);
        _settle(key.currency1, delta.amount1(), 0);
        return abi.encode(delta);
    }
}

/// @dev An ordinary contract trader. Fault injection lives only in this test helper.
contract PoolTraderHarness is PoolSettler {
    error NetOutputTooSmall(uint256 actual, uint256 minimum);

    constructor(IPoolManager manager_) PoolSettler(manager_) {}

    function swap(PoolKey memory key, bool buy, int256 amount, uint256 minimumNet, uint256 shortfall)
        public
        returns (BalanceDelta)
    {
        return abi.decode(manager.unlock(abi.encode(key, buy, amount, minimumNet, shortfall)), (BalanceDelta));
    }

    function buyAndForward(PoolKey memory key, uint256 nativeInput, address recipient)
        external
        returns (BalanceDelta delta)
    {
        RAIToken token = RAIToken(Currency.unwrap(key.currency1));
        uint256 beforeBalance = token.balanceOf(address(this));
        delta = swap(key, true, -int256(nativeInput), 0, 0);
        require(token.transfer(recipient, token.balanceOf(address(this)) - beforeBalance), "forward failed");
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(manager), "not manager");
        (PoolKey memory key, bool buy, int256 amount, uint256 minimumNet, uint256 shortfall) =
            abi.decode(data, (PoolKey, bool, int256, uint256, uint256));
        RAIToken token = RAIToken(Currency.unwrap(key.currency1));
        uint256 beforeBalance = buy ? token.balanceOf(address(this)) : address(this).balance;
        uint160 limit = buy ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1;
        BalanceDelta delta = manager.swap(key, IPoolManager.SwapParams(buy, amount, limit), "");
        _settle(key.currency0, delta.amount0(), buy ? shortfall : 0);
        _settle(key.currency1, delta.amount1(), buy ? 0 : shortfall);
        uint256 received = (buy ? token.balanceOf(address(this)) : address(this).balance) - beforeBalance;
        if (received < minimumNet) revert NetOutputTooSmall(received, minimumNet);
        return abi.encode(delta);
    }
}

abstract contract PoolFixture is RAITestBase {
    using StateLibrary for IPoolManager;
    using TransientStateLibrary for IPoolManager;

    address internal constant DISTRIBUTOR = address(uint160(uint256(keccak256("test swarm distributor"))));
    address internal constant REMAINDER = 0x000000000000000000000000000000000000dEaD;
    uint24 internal constant POOL_FEE = 12_500;
    IPoolManager internal manager;
    RAIToken internal token;
    PoolLaunchHarness internal factory;
    PoolTraderHarness internal trader;
    PoolKey internal key;
    BalanceDelta internal seedDelta;
    uint160 internal openingPrice;

    function _setUpPool() internal {
        // Execute the constructor at the immutable address: copying a separately deployed
        // runtime would trip v4's NoDelegateCall immutable-address guard.
        vm.etch(MANAGER, abi.encodePacked(type(PoolManager).creationCode, abi.encode(address(this))));
        (bool built, bytes memory runtime) = MANAGER.call("");
        require(built && runtime.length != 0, "could not construct PoolManager in place");
        vm.etch(MANAGER, runtime);
        manager = IPoolManager(MANAGER);
        factory = new PoolLaunchHarness(manager);
        token = factory.token();
        _assertEq(token.balanceOf(address(factory)), SUPPLY, "factory did not receive the entire mint");
        key = PoolKey(Currency.wrap(address(0)), Currency.wrap(address(token)), POOL_FEE, 60, IHooks(address(0)));
        // ETH sorts first. 1 ETH / 1e9 RAI => price(token1/token0) = 1e9 in minor units.
        // The manifest's inverse-order provenance price is not the opening price for this order.
        openingPrice = uint160(_sqrt((SUPPLY / 1 ether) << 192));
        seedDelta = factory.seed(key, DISTRIBUTOR, REMAINDER, openingPrice);
        trader = new PoolTraderHarness(manager);
        vm.deal(address(trader), 10 ether);
    }

    function _assertSettled() internal view {
        require(!manager.isUnlocked(), "manager remained unlocked");
        _assertEq(manager.getNonzeroDeltaCount(), 0, "unsettled currency debt");
        require(manager.currencyDelta(address(trader), key.currency0) == 0, "trader native debt");
        require(manager.currencyDelta(address(trader), key.currency1) == 0, "trader token debt");
        require(manager.currencyDelta(address(factory), key.currency0) == 0, "factory native debt");
        require(manager.currencyDelta(address(factory), key.currency1) == 0, "factory token debt");
    }

    function _assertPoolConservation() internal view {
        _assertEq(token.totalSupply(), SUPPLY, "supply changed");
        _assertEq(
            token.balanceOf(MANAGER) + token.balanceOf(CREATOR) + token.balanceOf(DISTRIBUTOR)
                + token.balanceOf(REMAINDER) + token.balanceOf(address(factory)) + token.balanceOf(address(trader)),
            SUPPLY,
            "pool flows lost or created tokens"
        );
    }

    function _sqrt(uint256 n) private pure returns (uint256 result) {
        result = n;
        uint256 next = (n + 1) / 2;
        while (next < result) {
            result = next;
            next = (n / next + next) / 2;
        }
    }
}
