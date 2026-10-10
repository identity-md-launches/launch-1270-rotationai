// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {RAIToken} from "../src/RAIToken.sol";

interface VmRAI {
    struct Log {
        bytes32[] topics;
        bytes data;
        address emitter;
    }

    function prank(address sender) external;
    function expectRevert(bytes calldata reason) external;
    function recordLogs() external;
    function getRecordedLogs() external returns (Log[] memory);
}

/// @dev Self-contained tests; no network, external packages, or runtime configuration needed.
contract RAITokenTest {
    VmRAI private constant vm = VmRAI(address(uint160(uint256(keccak256("hevm cheat code")))));
    uint256 private constant SUPPLY = 1_000_000_000e18;
    address private constant MANAGER = 0x8366a39CC670B4001A1121B8F6A443A643e40951;
    address private constant CREATOR = 0xD85D2A13bD490a21959F1EcABe8aC82221D253bc;
    address private constant ALICE = address(0xA11CE);
    address private constant BOB = address(0xB0B);
    address private constant ROUTER = address(0x1234);
    address private constant DISTRIBUTOR = address(0xD157);
    RAIToken private token;

    function setUp() public {
        token = new RAIToken();
    }

    function test_DeploymentMintsEverythingOnlyToDeployer() public view {
        require(token.totalSupply() == SUPPLY, "wrong supply");
        require(token.balanceOf(address(this)) == SUPPLY, "constructor distributed supply");
        require(token.balanceOf(MANAGER) == 0 && token.balanceOf(CREATOR) == 0, "premature allocation");
        require(token.decimals() == 18, "wrong denomination");
        require(keccak256(bytes(token.name())) == keccak256("RotationAI"), "wrong name");
        require(keccak256(bytes(token.symbol())) == keccak256("RAI"), "wrong ticker");
    }

    function test_DeploymentEmitsExactlyOneMintToDeployer() public {
        vm.recordLogs();
        token = new RAIToken();
        VmRAI.Log[] memory logs = vm.getRecordedLogs();
        require(logs.length == 1, "constructor emitted extra allocations");
        _assertTransfer(logs[0], address(0), address(this), SUPPLY);
        require(token.balanceOf(address(this)) == SUPPLY, "mint recipient mismatch");
    }

    function test_FactorySeedIsOneUntaxedTransferAfterWholeSwarmAllocation() public {
        token.transfer(DISTRIBUTOR, SUPPLY / 10);
        vm.recordLogs();
        token.transfer(MANAGER, SUPPLY * 9 / 10);
        VmRAI.Log[] memory logs = vm.getRecordedLogs();
        require(logs.length == 1, "seed split into multiple transfers");
        _assertTransfer(logs[0], address(this), MANAGER, 900_000_000e18);
        require(token.balanceOf(MANAGER) == 900_000_000e18, "seed arrived short");
        require(token.balanceOf(CREATOR) == 0, "seed taxed");
        require(token.balanceOf(address(this)) == 0, "factory retained allocation");
        vm.prank(DISTRIBUTOR);
        token.transfer(ALICE, SUPPLY / 10);
        require(token.balanceOf(ALICE) == 100_000_000e18, "claim arrived short");
        require(token.balanceOf(DISTRIBUTOR) == 0, "claim incomplete");
        _assertConservation();
    }

    function test_BuyPaysCreatorAndEmitsGrossConservingTransfers() public {
        token.transfer(MANAGER, 1000e18);
        vm.recordLogs();
        vm.prank(MANAGER);
        require(token.transfer(ALICE, 1000e18), "buy returned false");
        VmRAI.Log[] memory logs = vm.getRecordedLogs();
        require(logs.length == 2, "buy transfer events missing");
        _assertTransfer(logs[0], MANAGER, CREATOR, 30e18);
        _assertTransfer(logs[1], MANAGER, ALICE, 970e18);
        require(token.balanceOf(MANAGER) == 0, "gross debit incorrect");
        require(token.balanceOf(ALICE) == 970e18, "net buy incorrect");
        require(token.balanceOf(CREATOR) == 30e18, "tax incorrect");
        _assertConservation();
    }

    function test_BuyThenSellReturnsEntireNetBalanceToManager() public {
        token.transfer(MANAGER, 1000e18);
        vm.prank(MANAGER);
        token.transfer(ALICE, 1000e18);
        vm.prank(ALICE);
        token.transfer(MANAGER, 970e18);
        require(token.balanceOf(MANAGER) == 970e18, "sell arrived short");
        require(token.balanceOf(ALICE) == 0, "sell left tokens");
        require(token.balanceOf(CREATOR) == 30e18, "sell taxed");
        _assertConservation();
    }

    function test_WalletAndCreatorTransfersAreUntaxed() public {
        token.transfer(ALICE, 1000e18);
        vm.prank(ALICE);
        token.transfer(BOB, 1000e18);
        vm.prank(BOB);
        token.transfer(CREATOR, 1000e18);
        vm.prank(CREATOR);
        token.transfer(ALICE, 1000e18);
        require(token.balanceOf(ALICE) == 1000e18, "wallet transfer taxed");
        require(token.balanceOf(BOB) == 0 && token.balanceOf(CREATOR) == 0, "unexpected balance");
        _assertConservation();
    }

    function test_TransferFromUsesSourceNotCallerAndSpendsGrossAllowance() public {
        token.transfer(MANAGER, 1000e18);
        vm.prank(MANAGER);
        token.approve(ROUTER, 1000e18);
        vm.prank(ROUTER);
        token.transferFrom(MANAGER, ALICE, 1000e18);
        require(token.allowance(MANAGER, ROUTER) == 0, "gross allowance not spent");
        require(token.balanceOf(ALICE) == 970e18, "router bypassed buy tax");
        require(token.balanceOf(CREATOR) == 30e18, "missing buy tax");
        vm.prank(ALICE);
        token.approve(ROUTER, 970e18);
        vm.prank(ROUTER);
        token.transferFrom(ALICE, MANAGER, 970e18);
        require(token.balanceOf(MANAGER) == 970e18, "router sell taxed");
        _assertConservation();
    }

    function test_PoolManagerAsSpenderDoesNotTaxWalletTransfer() public {
        token.transfer(ALICE, 1000e18);
        vm.prank(ALICE);
        token.approve(MANAGER, 1000e18);
        vm.prank(MANAGER);
        token.transferFrom(ALICE, BOB, 1000e18);
        require(token.balanceOf(BOB) == 1000e18, "caller mistaken for source");
        require(token.balanceOf(CREATOR) == 0, "wallet transfer taxed");
    }

    function test_InfiniteAllowancePersistsAndApprovalCanBeRevoked() public {
        token.approve(ROUTER, type(uint256).max);
        vm.prank(ROUTER);
        token.transferFrom(address(this), ALICE, 100e18);
        require(token.allowance(address(this), ROUTER) == type(uint256).max, "infinite approval spent");
        token.approve(ROUTER, 0);
        vm.expectRevert(abi.encodeWithSelector(RAIToken.ERC20InsufficientAllowance.selector, ROUTER, 0, 1));
        vm.prank(ROUTER);
        token.transferFrom(address(this), ALICE, 1);
    }

    function test_FailedBalanceTransferRestoresAllowanceAndAllBalances() public {
        token.transfer(MANAGER, 100e18);
        vm.prank(MANAGER);
        token.approve(ROUTER, 101e18);
        vm.expectRevert(abi.encodeWithSelector(RAIToken.ERC20InsufficientBalance.selector, MANAGER, 100e18, 101e18));
        vm.prank(ROUTER);
        token.transferFrom(MANAGER, ALICE, 101e18);
        require(token.allowance(MANAGER, ROUTER) == 101e18, "revert spent allowance");
        require(token.balanceOf(MANAGER) == 100e18, "failed debit applied");
        require(token.balanceOf(CREATOR) == 0 && token.balanceOf(ALICE) == 0, "failed tax applied");
    }

    function test_InsufficientGrossAllowanceCannotBeCoveredByNetAmount() public {
        token.transfer(MANAGER, 100e18);
        vm.prank(MANAGER);
        token.approve(ROUTER, 97e18);
        vm.expectRevert(abi.encodeWithSelector(RAIToken.ERC20InsufficientAllowance.selector, ROUTER, 97e18, 100e18));
        vm.prank(ROUTER);
        token.transferFrom(MANAGER, ALICE, 100e18);
        require(token.balanceOf(MANAGER) == 100e18 && token.balanceOf(CREATOR) == 0, "partial transfer");
    }

    function test_InvalidBuyReceiverPreservesAllowanceAndBalances() public {
        token.transfer(MANAGER, 100e18);
        vm.prank(MANAGER);
        token.approve(ROUTER, 100e18);
        vm.expectRevert(abi.encodeWithSelector(RAIToken.ERC20InvalidReceiver.selector, address(0)));
        vm.prank(ROUTER);
        token.transferFrom(MANAGER, address(0), 100e18);
        require(token.allowance(MANAGER, ROUTER) == 100e18, "failed buy spent allowance");
        require(token.balanceOf(MANAGER) == 100e18, "failed buy debited pool");
        require(token.balanceOf(CREATOR) == 0, "failed buy paid tax");
        require(token.balanceOf(address(0)) == 0, "failed buy burned tokens");
        _assertConservation();
    }

    function test_ZeroTransfersAndSelfTransfersPreserveSupply() public {
        token.transfer(ALICE, 0);
        token.transfer(address(this), SUPPLY);
        token.transfer(MANAGER, 100e18);
        vm.prank(MANAGER);
        token.transfer(ALICE, 0);
        vm.prank(MANAGER);
        token.transfer(MANAGER, 100e18);
        require(token.balanceOf(MANAGER) == 100e18, "incoming self-transfer taxed");
        require(token.balanceOf(CREATOR) == 0, "self-transfer tax");
        _assertConservation();
    }

    function test_BuyToTaxRecipientCreditsGrossAmountWithoutDuplication() public {
        token.transfer(MANAGER, 100e18);
        vm.prank(MANAGER);
        token.transfer(CREATOR, 100e18);
        require(token.balanceOf(CREATOR) == 100e18, "recipient overlap accounting");
        require(token.balanceOf(MANAGER) == 0, "manager debit incorrect");
        _assertConservation();
    }

    function test_ZeroAddressesRevertAndCannotBurnSupply() public {
        vm.expectRevert(abi.encodeWithSelector(RAIToken.ERC20InvalidReceiver.selector, address(0)));
        token.transfer(address(0), 1);
        vm.expectRevert(abi.encodeWithSelector(RAIToken.ERC20InvalidSpender.selector, address(0)));
        token.approve(address(0), 1);
        vm.expectRevert(abi.encodeWithSelector(RAIToken.ERC20InvalidSender.selector, address(0)));
        token.transferFrom(address(0), ALICE, 0);
        require(token.balanceOf(address(this)) == SUPPLY, "supply burned");
        _assertConservation();
    }

    function test_MaxUintTransferRevertsBeforeTaxArithmetic() public {
        token.transfer(MANAGER, SUPPLY);
        vm.expectRevert(
            abi.encodeWithSelector(RAIToken.ERC20InsufficientBalance.selector, MANAGER, SUPPLY, type(uint256).max)
        );
        vm.prank(MANAGER);
        token.transfer(ALICE, type(uint256).max);
        _assertConservation();
    }

    function test_TaxRoundingAtSmallestUnits() public {
        token.transfer(MANAGER, 100);
        vm.prank(MANAGER);
        token.transfer(ALICE, 33);
        require(token.balanceOf(ALICE) == 33 && token.balanceOf(CREATOR) == 0, "round-down boundary");
        vm.prank(MANAGER);
        token.transfer(BOB, 34);
        require(token.balanceOf(BOB) == 33 && token.balanceOf(CREATOR) == 1, "first taxed unit");
        _assertConservation();
    }

    function test_AdminAndMintSelectorsAreAbsentForDeployerAndStranger() public {
        string[19] memory signatures = [
            "owner()",
            "mint(address,uint256)",
            "mint(uint256)",
            "mint()",
            "setOwner(address)",
            "transferOwnership(address)",
            "setTaxRate(uint256)",
            "setTaxBps(uint256)",
            "setTaxRecipient(address)",
            "setPoolManager(address)",
            "initialize(address)",
            "upgradeTo(address)",
            "pause()",
            "unpause()",
            "blacklist(address)",
            "freeze(address)",
            "burn(uint256)",
            "burnFrom(address,uint256)",
            "seize(address)"
        ];
        token.transfer(ALICE, 100e18);
        for (uint256 i; i < signatures.length; ++i) {
            bytes memory data = abi.encodeWithSignature(signatures[i], BOB, 100e18);
            (bool ok,) = address(token).call(data);
            require(!ok, signatures[i]);
            vm.prank(BOB);
            (ok,) = address(token).call(data);
            require(!ok, signatures[i]);
        }
        vm.prank(ALICE);
        token.transfer(BOB, 100e18);
        require(token.balanceOf(BOB) == 100e18, "holder frozen or seized");
        require(token.BUY_TAX_BPS() == 300 && token.TAX_RECIPIENT() == CREATOR, "parameters changed");
        require(token.POOL_MANAGER() == MANAGER, "manager changed");
        _assertConservation();
    }

    function test_DeployerCannotSpendHolderBalanceWithoutApproval() public {
        token.transfer(ALICE, 100e18);
        vm.expectRevert(abi.encodeWithSelector(RAIToken.ERC20InsufficientAllowance.selector, address(this), 0, 1));
        token.transferFrom(ALICE, address(this), 1);
        require(token.balanceOf(ALICE) == 100e18, "deployer privilege");
    }

    function test_RuntimeContainsNoForbiddenOpcodes() public view {
        bytes memory runtime = address(token).code;
        for (uint256 i; i < runtime.length; ++i) {
            uint8 op = uint8(runtime[i]);
            if (op >= 0x60 && op <= 0x7f) {
                i += op - 0x5f;
            } else {
                require(op != 0xf4 && op != 0xf2 && op != 0xff, "forbidden runtime opcode");
            }
        }
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_BuySellConservesSupplyAndNeverShortsSell(uint256 seed) public {
        uint256 gross = seed % (SUPPLY + 1);
        token.transfer(MANAGER, gross);
        vm.prank(MANAGER);
        token.transfer(ALICE, gross);
        uint256 creator = token.balanceOf(CREATOR);
        uint256 buyer = token.balanceOf(ALICE);
        require(buyer + creator == gross, "buy lost or created tokens");
        // Bound the rounding error independently of the implementation's division.
        require(creator * 100 <= gross * 3 && (creator + 1) * 100 > gross * 3, "not 3% rounded down");
        vm.prank(ALICE);
        token.transfer(MANAGER, buyer);
        require(token.balanceOf(MANAGER) == buyer, "settlement shortfall");
        require(token.balanceOf(CREATOR) == creator, "sell taxed");
        _assertConservation();
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_ArbitraryTransferSequencesPreserveBalances(bytes32 seed) public {
        address[7] memory holders = [address(this), MANAGER, CREATOR, ALICE, BOB, ROUTER, DISTRIBUTOR];
        for (uint256 i; i < 64; ++i) {
            seed = keccak256(abi.encode(seed, i));
            address from = holders[uint256(seed) % holders.length];
            address to = holders[(uint256(seed) >> 32) % holders.length];
            uint256 beforeFrom = token.balanceOf(from);
            uint256 beforeTo = token.balanceOf(to);
            uint256 beforeCreator = token.balanceOf(CREATOR);
            uint256 amount = (uint256(seed) >> 64) % (beforeFrom + 1);
            vm.prank(from);
            token.transfer(to, amount);
            if (to == MANAGER && from != MANAGER) {
                require(token.balanceOf(MANAGER) - beforeTo == amount, "incoming settlement short");
            }
            if (from != MANAGER && to != CREATOR && from != CREATOR) {
                require(token.balanceOf(CREATOR) == beforeCreator, "non-buy paid tax");
            }
            if (from == to) require(token.balanceOf(from) == beforeFrom, "self-transfer changed balance");
            _assertConservation();
        }
    }

    function _assertConservation() private view {
        uint256 sum = token.balanceOf(address(this)) + token.balanceOf(MANAGER) + token.balanceOf(CREATOR)
            + token.balanceOf(ALICE) + token.balanceOf(BOB) + token.balanceOf(ROUTER) + token.balanceOf(DISTRIBUTOR);
        require(sum == SUPPLY, "balances do not sum to fixed supply");
        require(token.totalSupply() == SUPPLY, "supply changed");
    }

    function _assertTransfer(VmRAI.Log memory entry, address from, address to, uint256 amount) private view {
        require(entry.emitter == address(token), "wrong emitter");
        require(entry.topics.length == 3, "wrong topic count");
        require(entry.topics[0] == keccak256("Transfer(address,address,uint256)"), "wrong event");
        require(entry.topics[1] == bytes32(uint256(uint160(from))), "wrong source");
        require(entry.topics[2] == bytes32(uint256(uint160(to))), "wrong destination");
        require(abi.decode(entry.data, (uint256)) == amount, "wrong event amount");
    }
}
