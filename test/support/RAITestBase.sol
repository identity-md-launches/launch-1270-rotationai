// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

interface VmRotation {
    struct Log {
        bytes32[] topics;
        bytes data;
        address emitter;
    }

    function prank(address sender) external;
    function expectRevert(bytes calldata reason) external;
    function expectRevert(bytes4 selector) external;
    function deal(address who, uint256 amount) external;
    function etch(address who, bytes calldata code) external;
    function recordLogs() external;
    function getRecordedLogs() external returns (Log[] memory);
}

/// @dev Small local test interface; no remappings, external installation, or RPC required.
abstract contract RAITestBase {
    VmRotation internal constant vm = VmRotation(address(uint160(uint256(keccak256("hevm cheat code")))));
    uint256 internal constant SUPPLY = 1_000_000_000e18;
    address internal constant MANAGER = 0x8366a39CC670B4001A1121B8F6A443A643e40951;
    address internal constant CREATOR = 0xD85D2A13bD490a21959F1EcABe8aC82221D253bc;

    function _assertEq(uint256 actual, uint256 expected, string memory reason) internal pure {
        require(actual == expected, reason);
    }

    /// @dev Verify the rounding property independently of the token's basis-point division.
    function _assertTax(uint256 gross, uint256 tax) internal pure {
        require(tax * 100 <= gross * 3, "creator received more than 3%");
        require((tax + 1) * 100 > gross * 3, "creator received less than floor(3%)");
    }
}
