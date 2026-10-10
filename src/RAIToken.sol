// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @notice RotationAI: fixed supply, with a fixed creator fee on PoolManager outflows.
/// @dev The launch factory deploys this contract, then distributes its own balance.
contract RAIToken {
    string public constant name = "RotationAI";
    string public constant symbol = "RAI";
    uint8 public constant decimals = 18;
    uint256 public constant totalSupply = 1_000_000_000 * 10 ** 18;

    address public constant POOL_MANAGER = 0x8366a39CC670B4001A1121B8F6A443A643e40951;
    address public constant TAX_RECIPIENT = 0xD85D2A13bD490a21959F1EcABe8aC82221D253bc;
    uint256 public constant BUY_TAX_BPS = 300;
    uint256 public constant BPS_DENOMINATOR = 10_000;

    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    error ERC20InvalidSender(address sender);
    error ERC20InvalidReceiver(address receiver);
    error ERC20InvalidSpender(address spender);
    error ERC20InsufficientBalance(address sender, uint256 balance, uint256 needed);
    error ERC20InsufficientAllowance(address spender, uint256 allowance, uint256 needed);

    constructor() {
        balanceOf[msg.sender] = totalSupply;
        emit Transfer(address(0), msg.sender, totalSupply);
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        _transfer(msg.sender, to, amount);
        return true;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        if (spender == address(0)) revert ERC20InvalidSpender(spender);
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 available = allowance[from][msg.sender];
        if (available != type(uint256).max) {
            if (available < amount) revert ERC20InsufficientAllowance(msg.sender, available, amount);
            allowance[from][msg.sender] = available - amount;
        }
        _transfer(from, to, amount);
        return true;
    }

    function _transfer(address from, address to, uint256 amount) private {
        if (from == address(0)) revert ERC20InvalidSender(from);
        if (to == address(0)) revert ERC20InvalidReceiver(to);

        uint256 available = balanceOf[from];
        if (available < amount) revert ERC20InsufficientBalance(from, available, amount);
        balanceOf[from] = available - amount;

        // Incoming settlements, including a PoolManager self-transfer, always arrive whole.
        // The checked balance bounds amount by the fixed supply, so multiplication is safe.
        uint256 tax = 0;
        if (from == POOL_MANAGER && to != POOL_MANAGER) {
            tax = amount * BUY_TAX_BPS / BPS_DENOMINATOR;
            if (tax != 0) {
                balanceOf[TAX_RECIPIENT] += tax;
                emit Transfer(from, TAX_RECIPIENT, tax);
            }
        }

        uint256 received = amount - tax;
        balanceOf[to] += received;
        emit Transfer(from, to, received);
    }
}
