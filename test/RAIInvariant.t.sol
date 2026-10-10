// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {RAIToken} from "../src/RAIToken.sol";
import {RAITestBase} from "./support/RAITestBase.sol";

/// @dev Closed set of holders permits exact conservation checks without editing token storage.
/// Ghost accounting includes receiver/source/creator aliasing and persistent approvals.
contract RAIHandler is RAITestBase {
    RAIToken public immutable token;
    address[6] private actors;
    mapping(address => uint256) private expectedBalance;
    mapping(address => mapping(address => uint256)) private expectedAllowance;
    uint256 public successfulMoves;
    uint256 public rejectedCalls;

    constructor() {
        token = new RAIToken();
        actors = [
            address(this),
            MANAGER,
            CREATOR,
            address(uint160(uint256(keccak256("invariant alice")))),
            address(uint160(uint256(keccak256("invariant bob")))),
            address(uint160(uint256(keccak256("invariant distributor"))))
        ];
        expectedBalance[address(this)] = SUPPLY;
        _transfer(address(this), MANAGER, 900_000_000e18);
        _transfer(address(this), actors[5], 100_000_000e18);
    }

    function buy(uint256 receiver, uint256 amount) external {
        _transfer(MANAGER, _actor(receiver), amount % (expectedBalance[MANAGER] + 1));
    }

    function sell(uint256 seller, uint256 amount) external {
        address from = _actor(seller);
        _transfer(from, MANAGER, amount % (expectedBalance[from] + 1));
    }

    function move(uint256 sender, uint256 receiver, uint256 amount) external {
        address from = _actor(sender);
        _transfer(from, _actor(receiver), amount % (expectedBalance[from] + 1));
    }

    function approve(uint256 ownerSeed, uint256 spenderSeed, uint256 amountSeed, uint8 mode) external {
        address owner = _actor(ownerSeed);
        address spender = _actor(spenderSeed);
        uint256 amount = mode % 3 == 0 ? 0 : mode % 3 == 1 ? type(uint256).max : amountSeed % (SUPPLY + 1);
        vm.prank(owner);
        require(token.approve(spender, amount), "approve returned false");
        expectedAllowance[owner][spender] = amount;
    }

    function spend(uint256 ownerSeed, uint256 spenderSeed, uint256 receiverSeed, uint256 amountSeed) external {
        address owner = _actor(ownerSeed);
        address spender = _actor(spenderSeed);
        address recipient = _actor(receiverSeed);
        uint256 available = expectedAllowance[owner][spender];
        uint256 limit = expectedBalance[owner] < available ? expectedBalance[owner] : available;
        uint256 amount = amountSeed % (limit + 1);
        vm.prank(spender);
        require(token.transferFrom(owner, recipient, amount), "transferFrom returned false");
        if (available != type(uint256).max) expectedAllowance[owner][spender] -= amount;
        _account(owner, recipient, amount);
    }

    function rejectTransfer(uint256 ownerSeed, bool zeroReceiver) external {
        address owner = _actor(ownerSeed);
        uint256 held = expectedBalance[owner];
        uint256 amount = zeroReceiver ? held : held + 1;
        address recipient = zeroReceiver ? address(0) : _actor((ownerSeed % actors.length) + 1);
        bytes memory expectedError = zeroReceiver
            ? abi.encodeWithSelector(RAIToken.ERC20InvalidReceiver.selector, address(0))
            : abi.encodeWithSelector(RAIToken.ERC20InsufficientBalance.selector, owner, held, amount);
        vm.prank(owner);
        (bool ok, bytes memory errorData) = address(token).call(abi.encodeCall(token.transfer, (recipient, amount)));
        require(!ok && keccak256(errorData) == keccak256(expectedError), "bad direct transfer was not rejected");
        rejectedCalls++;
    }

    function rejectSpend(uint256 ownerSeed, uint256 spenderSeed, uint256 receiverSeed, bool exhaustAllowance) external {
        address owner = _actor(ownerSeed);
        address spender = _actor(spenderSeed);
        uint256 held = expectedBalance[owner];
        uint256 available = expectedAllowance[owner][spender];
        uint256 amount = exhaustAllowance && available != type(uint256).max ? available + 1 : held + 1;
        bytes memory expectedError = available < amount
            ? abi.encodeWithSelector(RAIToken.ERC20InsufficientAllowance.selector, spender, available, amount)
            : abi.encodeWithSelector(RAIToken.ERC20InsufficientBalance.selector, owner, held, amount);
        vm.prank(spender);
        (bool ok, bytes memory errorData) =
            address(token).call(abi.encodeCall(token.transferFrom, (owner, _actor(receiverSeed), amount)));
        require(!ok && keccak256(errorData) == keccak256(expectedError), "bad delegated transfer was not rejected");
        // Ghost allowance remains unchanged, including when _transfer reverts after its decrement.
        rejectedCalls++;
    }

    function tryAdmin(uint256 callerSeed, uint256 actionSeed) external {
        bytes[8] memory calls = [
            abi.encodeWithSignature("mint(address,uint256)", actors[3], 1),
            abi.encodeWithSignature("setTaxRate(uint256)", 0),
            abi.encodeWithSignature("setTaxRecipient(address)", actors[3]),
            abi.encodeWithSignature("setPoolManager(address)", actors[3]),
            abi.encodeWithSignature("pause()"),
            abi.encodeWithSignature("transferOwnership(address)", actors[3]),
            abi.encodeWithSignature("burnFrom(address,uint256)", MANAGER, 1),
            abi.encodeWithSignature("upgradeTo(address)", actors[3])
        ];
        vm.prank(_actor(callerSeed));
        (bool ok,) = address(token).call(calls[actionSeed % calls.length]);
        require(!ok, "admin function is callable");
        rejectedCalls++;
    }

    function assertModel() external view {
        uint256 sum;
        for (uint256 i; i < actors.length; ++i) {
            address actor = actors[i];
            uint256 actual = token.balanceOf(actor);
            _assertEq(actual, expectedBalance[actor], "balance disagrees with the ghost ledger");
            sum += actual;
            for (uint256 j; j < actors.length; ++j) {
                _assertEq(
                    token.allowance(actor, actors[j]),
                    expectedAllowance[actor][actors[j]],
                    "allowance disagrees with successful gross spending"
                );
            }
        }
        _assertEq(sum, SUPPLY, "balances no longer sum to fixed supply");
        _assertEq(token.totalSupply(), SUPPLY, "supply changed");
        _assertEq(token.balanceOf(address(0)), 0, "tokens were burned to zero");
        _assertEq(token.BUY_TAX_BPS(), 300, "tax rate changed");
        _assertEq(token.BPS_DENOMINATOR(), 10_000, "tax denominator changed");
        require(token.TAX_RECIPIENT() == CREATOR && token.POOL_MANAGER() == MANAGER, "fixed address changed");
    }

    function _transfer(address from, address to, uint256 amount) private {
        vm.prank(from);
        require(token.transfer(to, amount), "transfer returned false");
        _account(from, to, amount);
    }

    function _account(address from, address to, uint256 gross) private {
        // A quotient/remainder oracle avoids copying the implementation's BPS expression.
        uint256 tax = from == MANAGER && to != MANAGER ? (gross / 100) * 3 + ((gross % 100) * 3) / 100 : 0;
        expectedBalance[from] -= gross;
        expectedBalance[to] += gross - tax;
        expectedBalance[CREATOR] += tax;
        successfulMoves++;
    }

    function _actor(uint256 seed) private view returns (address) {
        return actors[seed % actors.length];
    }
}

/// @notice Short campaigns; an unexpected handler revert fails instead of being discarded.
/// forge-config: default.invariant.runs = 64
/// forge-config: default.invariant.depth = 64
/// forge-config: default.invariant.fail-on-revert = true
contract RAIInvariantTest {
    struct FuzzSelector {
        address addr;
        bytes4[] selectors;
    }

    RAIHandler private handler;

    function setUp() public {
        handler = new RAIHandler();
    }

    // Foundry's standard target getters, implemented locally to avoid a forge-std dependency.
    function targetContracts() external view returns (address[] memory targets) {
        targets = new address[](1);
        targets[0] = address(handler);
    }

    function targetSelectors() external view returns (FuzzSelector[] memory targets) {
        bytes4[] memory selectors = new bytes4[](8);
        selectors[0] = RAIHandler.buy.selector;
        selectors[1] = RAIHandler.sell.selector;
        selectors[2] = RAIHandler.move.selector;
        selectors[3] = RAIHandler.approve.selector;
        selectors[4] = RAIHandler.spend.selector;
        selectors[5] = RAIHandler.rejectTransfer.selector;
        selectors[6] = RAIHandler.rejectSpend.selector;
        selectors[7] = RAIHandler.tryAdmin.selector;
        targets = new FuzzSelector[](1);
        targets[0] = FuzzSelector(address(handler), selectors);
    }

    function invariant_BalancesAllowancesAndFixedParametersMatchTheModel() public view {
        handler.assertModel();
    }

    function test_HandlerCarriesStateAcrossApprovalsFailuresAndBuys() public {
        handler.buy(3, 1_000e18);
        handler.approve(3, 4, 970e18, 2);
        handler.rejectSpend(3, 4, 1, true);
        handler.spend(3, 4, 1, 970e18);
        handler.rejectTransfer(1, true);
        handler.tryAdmin(0, 0);
        handler.assertModel();
        require(handler.successfulMoves() == 4 && handler.rejectedCalls() == 3, "handler did not exercise paths");
    }
}
