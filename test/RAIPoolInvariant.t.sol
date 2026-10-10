// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {RAIToken} from "../src/RAIToken.sol";
import {RAITestBase} from "./support/RAITestBase.sol";
import {PoolFixture, PoolLaunchHarness, PoolTraderHarness} from "./support/PoolHarness.sol";
import {IPoolManager} from "./vendor/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "./vendor/v4-core/src/types/PoolKey.sol";
import {BalanceDelta} from "./vendor/v4-core/src/types/BalanceDelta.sol";
import {StateLibrary} from "./vendor/v4-core/src/libraries/StateLibrary.sol";

contract RAIPoolHandler is RAITestBase {
    RAIToken private immutable token;
    PoolTraderHarness private immutable trader;
    PoolLaunchHarness private immutable factory;
    PoolKey private key;
    uint256 public expectedCreator;

    constructor(RAIToken token_, PoolTraderHarness trader_, PoolLaunchHarness factory_, PoolKey memory key_) {
        token = token_;
        trader = trader_;
        factory = factory_;
        key = key_;
    }

    function buy(uint256 seed) external {
        uint256 budget = address(trader).balance;
        if (budget == 0) return;
        if (budget > 0.01 ether) budget = 0.01 ether;
        uint256 amount = 1 + seed % budget;
        uint256 beforeBuyer = token.balanceOf(address(trader));
        uint256 beforePool = token.balanceOf(MANAGER);
        uint256 beforeEth = address(trader).balance;
        BalanceDelta delta = trader.swap(key, true, -int256(amount), 0, 0);
        require(delta.amount0() <= 0 && delta.amount1() >= 0, "buy signs wrong");
        uint256 gross = uint128(delta.amount1());
        uint256 tax = token.balanceOf(CREATOR) - expectedCreator;
        _assertTax(gross, tax);
        _assertEq(token.balanceOf(address(trader)) - beforeBuyer, gross - tax, "random buy receipt wrong");
        _assertEq(beforePool - token.balanceOf(MANAGER), gross, "random buy pool debit wrong");
        _assertEq(beforeEth - address(trader).balance, uint256(-int256(delta.amount0())), "random native debit wrong");
        expectedCreator += tax;
    }

    function sell(uint256 seed) external {
        uint256 held = token.balanceOf(address(trader));
        if (held == 0) return;
        uint256 amount = 1 + seed % held;
        uint256 beforePool = token.balanceOf(MANAGER);
        uint256 beforeEth = address(trader).balance;
        BalanceDelta delta = trader.swap(key, false, -int256(amount), 0, 0);
        require(delta.amount0() >= 0 && delta.amount1() <= 0, "sell signs wrong");
        uint256 spent = uint256(-int256(delta.amount1()));
        _assertEq(spent, amount, "random sell not fully consumed");
        _assertEq(held - token.balanceOf(address(trader)), amount, "random sell balance wrong");
        _assertEq(token.balanceOf(MANAGER) - beforePool, amount, "random sell arrived short");
        _assertEq(token.balanceOf(CREATOR), expectedCreator, "random sell taxed");
        _assertEq(address(trader).balance - beforeEth, uint128(delta.amount0()), "random native receipt wrong");
    }

    function collectFees() external {
        uint256 beforeFactory = token.balanceOf(address(factory));
        uint256 beforePool = token.balanceOf(MANAGER);
        uint256 beforeEth = address(factory).balance;
        BalanceDelta fees = factory.collectFees();
        require(fees.amount0() >= 0 && fees.amount1() >= 0, "collecting fees created debt");
        uint256 gross = uint128(fees.amount1());
        uint256 tax = token.balanceOf(CREATOR) - expectedCreator;
        _assertTax(gross, tax);
        _assertEq(token.balanceOf(address(factory)) - beforeFactory, gross - tax, "LP token fee receipt wrong");
        _assertEq(beforePool - token.balanceOf(MANAGER), gross, "LP token fee pool debit wrong");
        _assertEq(address(factory).balance - beforeEth, uint128(fees.amount0()), "LP native receipt wrong");
        expectedCreator += tax;
    }
}

/// forge-config: default.invariant.runs = 64
/// forge-config: default.invariant.depth = 32
/// forge-config: default.invariant.fail-on-revert = true
contract RAIPoolInvariantTest is PoolFixture {
    using StateLibrary for IPoolManager;

    struct FuzzSelector {
        address addr;
        bytes4[] selectors;
    }

    RAIPoolHandler private handler;

    function setUp() public {
        _setUpPool();
        handler = new RAIPoolHandler(token, trader, factory, key);
        handler.buy(0.001 ether - 1);
    }

    function targetContracts() external view returns (address[] memory targets) {
        targets = new address[](1);
        targets[0] = address(handler);
    }

    function targetSelectors() external view returns (FuzzSelector[] memory targets) {
        bytes4[] memory selectors = new bytes4[](3);
        selectors[0] = RAIPoolHandler.buy.selector;
        selectors[1] = RAIPoolHandler.sell.selector;
        selectors[2] = RAIPoolHandler.collectFees.selector;
        targets = new FuzzSelector[](1);
        targets[0] = FuzzSelector(address(handler), selectors);
    }

    function invariant_SwapsAndFeeCollectionsConserveValueAndLeaveNoDebt() public view {
        _assertPoolConservation();
        _assertSettled();
        _assertEq(token.balanceOf(CREATOR), handler.expectedCreator(), "creator balance changed unexpectedly");
        _assertEq(MANAGER.balance + address(trader).balance + address(factory).balance, 10 ether, "native value lost");
        (,,, uint24 fee) = manager.getSlot0(key.toId());
        _assertEq(fee, 12_500, "LP fee changed during swaps");
    }
}
