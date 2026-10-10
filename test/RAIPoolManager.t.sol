// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {PoolFixture, PoolTraderHarness} from "./support/PoolHarness.sol";
import {VmRotation} from "./support/RAITestBase.sol";
import {IPoolManager} from "./vendor/v4-core/src/interfaces/IPoolManager.sol";
import {BalanceDelta} from "./vendor/v4-core/src/types/BalanceDelta.sol";
import {StateLibrary} from "./vendor/v4-core/src/libraries/StateLibrary.sol";

/// @notice Runs actual v4-core bytecode locally at RAI's immutable PoolManager address.
contract RAIPoolManagerTest is PoolFixture {
    using StateLibrary for IPoolManager;

    function setUp() public {
        vm.recordLogs();
        _setUpPool();
    }

    function test_FactorySeedsSingleSidedLiquidityWithOneUntaxedTokenPayment() public {
        uint256 seedTransfers;
        uint256 seeded;
        VmRotation.Log[] memory entries = vm.getRecordedLogs();
        for (uint256 i; i < entries.length; ++i) {
            if (
                entries[i].emitter == address(token) && entries[i].topics.length == 3
                    && entries[i].topics[0] == keccak256("Transfer(address,address,uint256)")
                    && entries[i].topics[2] == bytes32(uint256(uint160(MANAGER)))
            ) {
                require(entries[i].topics[1] == bytes32(uint256(uint160(address(factory)))), "not factory seed");
                seedTransfers++;
                seeded += abi.decode(entries[i].data, (uint256));
            }
        }
        _assertEq(seedTransfers, 1, "seed was split across transfers");
        require(seedDelta.amount0() == 0 && seedDelta.amount1() < 0, "seed was not RAI only");
        _assertEq(seeded, uint256(-int256(seedDelta.amount1())), "seed debt mismatch");
        _assertEq(token.balanceOf(MANAGER), seeded, "seed taxed");
        // v4 liquidity is an integer. The factory forwards its tiny rounding remainder.
        _assertEq(seeded + token.balanceOf(REMAINDER), 900_000_000e18, "pool budget changed");
        require(seeded > 899_999_999e18, "seed left material allocation unused");
        _assertEq(token.balanceOf(DISTRIBUTOR), 100_000_000e18, "swarm shortfall");
        _assertEq(token.balanceOf(address(factory)), 0, "factory kept supply");
        _assertEq(token.balanceOf(CREATOR), 0, "launch paid buy tax");
        _assertEq(MANAGER.balance, 0, "seed needed native currency");
        _assertSettled();
        _assertPoolConservation();
    }

    function test_PoolUses12500Fee60SpacingAndEconomicsPriceInActualCurrencyOrder() public view {
        (uint160 price,, uint24 protocolFee, uint24 lpFee) = manager.getSlot0(key.toId());
        _assertEq(lpFee, 12_500, "LP fee is not 1.25%");
        _assertEq(protocolFee, 0, "unexpected protocol fee in fixture");
        require(key.tickSpacing == 60, "tick spacing changed");
        _assertEq(price, openingPrice, "wrong opening price");
        uint256 ratioX192 = 1_000_000_000 * (uint256(1) << 192);
        require(uint256(price) * price <= ratioX192, "opening cap too high");
        require((uint256(price) + 1) * (uint256(price) + 1) > ratioX192, "opening cap too low");
    }

    function test_BuyAndSellWithLPFeesLeaveNoSettlementDebt() public {
        uint256 bought = _buy(0.01 ether);
        uint256 creatorBefore = token.balanceOf(CREATOR);
        uint256 managerBefore = token.balanceOf(MANAGER);
        uint256 ethBefore = address(trader).balance;
        BalanceDelta sell = trader.swap(key, false, -int256(bought), 1, 0);
        require(sell.amount0() > 0 && sell.amount1() < 0, "wrong sell direction");
        _assertEq(uint256(-int256(sell.amount1())), bought, "sell not fully consumed");
        _assertEq(token.balanceOf(address(trader)), 0, "buyer could not sell everything");
        _assertEq(token.balanceOf(MANAGER) - managerBefore, bought, "sell settlement taxed");
        _assertEq(token.balanceOf(CREATOR), creatorBefore, "sell paid creator again");
        _assertEq(address(trader).balance - ethBefore, uint128(sell.amount0()), "native output mismatch");
        (uint256 growth0, uint256 growth1) = manager.getFeeGrowthGlobals(key.toId());
        require(growth0 > 0 && growth1 > 0, "swaps did not accrue LP fees in both currencies");
        require(address(trader).balance < 10 ether, "round trip ignored fees");
        _assertSettled();
        _assertPoolConservation();
    }

    function test_ExactOutputBuyReturnsGrossPoolDeltaAndNetTokens() public {
        uint256 gross = 1_000e18;
        uint256 poolBefore = token.balanceOf(MANAGER);
        BalanceDelta delta = trader.swap(key, true, int256(gross), 970e18, 0);
        _assertEq(uint128(delta.amount1()), gross, "exact output not fulfilled");
        _assertEq(poolBefore - token.balanceOf(MANAGER), gross, "gross pool debit wrong");
        _assertEq(token.balanceOf(address(trader)), 970e18, "net exact output wrong");
        _assertEq(token.balanceOf(CREATOR), 30e18, "exact output tax missing");
        _assertSettled();
        _assertPoolConservation();
    }

    function test_ExactOutputSellPaysFullInputWithoutCreatorTax() public {
        _buy(0.01 ether);
        uint256 traderBefore = token.balanceOf(address(trader));
        uint256 poolBefore = token.balanceOf(MANAGER);
        uint256 creatorBefore = token.balanceOf(CREATOR);
        uint256 ethBefore = address(trader).balance;
        BalanceDelta delta = trader.swap(key, false, int256(0.001 ether), 0.001 ether, 0);
        uint256 spent = uint256(-int256(delta.amount1()));
        _assertEq(uint128(delta.amount0()), 0.001 ether, "native exact output wrong");
        _assertEq(address(trader).balance - ethBefore, 0.001 ether, "native receipt wrong");
        _assertEq(traderBefore - token.balanceOf(address(trader)), spent, "input debit wrong");
        _assertEq(token.balanceOf(MANAGER) - poolBefore, spent, "exact output sell taxed");
        _assertEq(token.balanceOf(CREATOR), creatorBefore, "sell paid creator tax");
        _assertSettled();
        _assertPoolConservation();
    }

    function test_RouterForwardsActualNetReceiptWithoutASecondTax() public {
        address recipient = address(uint160(uint256(keccak256("router recipient"))));
        BalanceDelta delta = trader.buyAndForward(key, 0.01 ether, recipient);
        uint256 tax = token.balanceOf(CREATOR);
        uint256 gross = uint128(delta.amount1());
        _assertTax(gross, tax);
        _assertEq(token.balanceOf(recipient), gross - tax, "forwarding net amount failed");
        _assertEq(token.balanceOf(address(trader)), 0, "router retained tokens");
        _assertEq(
            token.balanceOf(MANAGER) + token.balanceOf(CREATOR) + token.balanceOf(DISTRIBUTOR)
                + token.balanceOf(REMAINDER) + token.balanceOf(recipient),
            SUPPLY,
            "forwarding changed supply"
        );
        _assertSettled();
    }

    function test_CollectedNativeLPFeeIs12500PerMillionOfBuyInput() public {
        _buy(0.01 ether);
        uint256 creatorBefore = token.balanceOf(CREATOR);
        BalanceDelta fees = factory.collectFees();
        uint256 expectedFee = 0.01 ether * 12_500 / 1_000_000;
        uint256 collected = uint128(fees.amount0());
        // The single LP position loses at most one wei in fee-growth rounding.
        require(collected <= expectedFee && expectedFee - collected <= 1, "LP fee is not 1.25%");
        _assertEq(address(factory).balance, collected, "LP native receipt wrong");
        require(fees.amount1() == 0, "native buy accrued token LP fees");
        _assertEq(token.balanceOf(CREATOR), creatorBefore, "native fee collection taxed RAI");
        BalanceDelta again = factory.collectFees();
        require(again.amount0() == 0 && again.amount1() == 0, "LP fees claimable twice");
        _assertSettled();
        _assertPoolConservation();
    }

    function test_LiquidityWithdrawalAlsoTaxesManagerOutflowsAndSettles() public {
        _buy(0.01 ether);
        uint256 poolBefore = token.balanceOf(MANAGER);
        uint256 creatorBefore = token.balanceOf(CREATOR);
        BalanceDelta withdrawn = factory.removeLiquidity();
        require(withdrawn.amount0() > 0 && withdrawn.amount1() > 0, "withdrawal returned nothing");
        uint256 gross = uint128(withdrawn.amount1());
        uint256 tax = token.balanceOf(CREATOR) - creatorBefore;
        _assertTax(gross, tax);
        _assertEq(poolBefore - token.balanceOf(MANAGER), gross, "withdrawal gross debit wrong");
        _assertEq(token.balanceOf(address(factory)), gross - tax, "withdrawal net receipt wrong");
        _assertEq(manager.getLiquidity(key.toId()), 0, "liquidity remains");
        _assertSettled();
        _assertPoolConservation();
    }

    function test_UnderpaidBuyRevertsAndRollsBackTaxAndPoolState() public {
        bytes32 beforeState = _stateDigest();
        vm.expectRevert(IPoolManager.CurrencyNotSettled.selector);
        trader.swap(key, true, -int256(0.01 ether), 0, 1);
        require(_stateDigest() == beforeState, "failed buy changed state");
        _assertSettled();
        // The reverted unlock must not poison the next trade.
        _buy(0.01 ether);
    }

    function test_UnderpaidSellRevertsAndRollsBackNativeOutput() public {
        uint256 bought = _buy(0.01 ether);
        bytes32 beforeState = _stateDigest();
        vm.expectRevert(IPoolManager.CurrencyNotSettled.selector);
        trader.swap(key, false, -int256(bought), 0, 1);
        require(_stateDigest() == beforeState, "failed sell changed state");
        _assertSettled();
        trader.swap(key, false, -int256(bought), 1, 0);
        _assertEq(token.balanceOf(address(trader)), 0, "valid sell failed after revert");
        _assertSettled();
        _assertPoolConservation();
    }

    function test_MinimumOutputMustBeCheckedAgainstNetReceipt() public {
        bytes32 beforeState = _stateDigest();
        vm.expectRevert(abi.encodeWithSelector(PoolTraderHarness.NetOutputTooSmall.selector, 970e18, 1_000e18));
        trader.swap(key, true, int256(1_000e18), 1_000e18, 0);
        require(_stateDigest() == beforeState, "slippage revert changed state");
        _assertSettled();
    }

    function test_ZeroSwapRevertsWithoutChangingBalances() public {
        bytes32 beforeState = _stateDigest();
        vm.expectRevert(IPoolManager.SwapAmountCannotBeZero.selector);
        trader.swap(key, true, 0, 0, 0);
        require(_stateDigest() == beforeState, "zero swap changed state");
        _assertSettled();
    }

    function test_StaticPoolFeeCannotBeUpdated() public {
        vm.expectRevert(IPoolManager.UnauthorizedDynamicLPFeeUpdate.selector);
        manager.updateDynamicLPFee(key, 0);
        (,,, uint24 fee) = manager.getSlot0(key.toId());
        _assertEq(fee, 12_500, "pool fee changed");
    }

    function testFuzz_BuyThenSellThroughPoolManager(uint256 seed) public {
        uint256 nativeInput = 1e9 + seed % (0.02 ether - 1e9 + 1);
        uint256 bought = _buy(nativeInput);
        uint256 tax = token.balanceOf(CREATOR);
        uint256 beforePool = token.balanceOf(MANAGER);
        trader.swap(key, false, -int256(bought), 0, 0);
        _assertEq(token.balanceOf(MANAGER) - beforePool, bought, "fuzz sell shortfall");
        _assertEq(token.balanceOf(address(trader)), 0, "fuzz sell incomplete");
        _assertEq(token.balanceOf(CREATOR), tax, "fuzz sell taxed");
        _assertSettled();
        _assertPoolConservation();
    }

    function _buy(uint256 nativeInput) private returns (uint256 net) {
        uint256 beforePool = token.balanceOf(MANAGER);
        uint256 beforeTrader = token.balanceOf(address(trader));
        uint256 beforeCreator = token.balanceOf(CREATOR);
        uint256 beforeNative = address(trader).balance;
        BalanceDelta delta = trader.swap(key, true, -int256(nativeInput), 1, 0);
        require(delta.amount0() < 0 && delta.amount1() > 0, "wrong buy direction");
        _assertEq(uint256(-int256(delta.amount0())), nativeInput, "buy input not fully consumed");
        _assertEq(beforeNative - address(trader).balance, nativeInput, "native buy debit wrong");
        uint256 gross = uint128(delta.amount1());
        uint256 tax = token.balanceOf(CREATOR) - beforeCreator;
        net = token.balanceOf(address(trader)) - beforeTrader;
        _assertTax(gross, tax);
        _assertEq(net + tax, gross, "buy receipt plus tax differs from gross output");
        _assertEq(beforePool - token.balanceOf(MANAGER), gross, "pool lost more than gross output");
        _assertSettled();
        _assertPoolConservation();
    }

    function _stateDigest() private view returns (bytes32) {
        (uint160 price, int24 tick, uint24 protocolFee, uint24 lpFee) = manager.getSlot0(key.toId());
        (uint256 fee0, uint256 fee1) = manager.getFeeGrowthGlobals(key.toId());
        bytes32 poolState = keccak256(abi.encode(price, tick, protocolFee, lpFee, fee0, fee1));
        return keccak256(
            abi.encode(
                poolState,
                token.balanceOf(MANAGER),
                token.balanceOf(address(trader)),
                token.balanceOf(CREATOR),
                MANAGER.balance,
                address(trader).balance,
                token.totalSupply()
            )
        );
    }
}
