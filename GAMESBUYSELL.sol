// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/* OpenZeppelin v5.4.0 raw imports (Remix compatible) */
import "https://raw.githubusercontent.com/OpenZeppelin/openzeppelin-contracts/v5.4.0/contracts/token/ERC20/ERC20.sol";
import "https://raw.githubusercontent.com/OpenZeppelin/openzeppelin-contracts/v5.4.0/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import "https://raw.githubusercontent.com/OpenZeppelin/openzeppelin-contracts/v5.4.0/contracts/token/ERC20/utils/SafeERC20.sol";
import "https://raw.githubusercontent.com/OpenZeppelin/openzeppelin-contracts/v5.4.0/contracts/access/Ownable.sol";
import "https://raw.githubusercontent.com/OpenZeppelin/openzeppelin-contracts/v5.4.0/contracts/utils/ReentrancyGuard.sol";

/**
 * Name  : GAMESBUYSELL
 * Symbol: GBS
 * Total : 9,000,000,000 (18 decimals - OZ ERC20 default)
 *
 * Tax: default 5% (min 0, max 10); no tax for owner/pair/router/exempt addresses.
 * Initial Distribution:
 *  - PRESALE    36.25%
 *  - LIQUIDITY  26.25%
 *  - GBS_WALLET 15%
 *  - COMMUNITY  12.5%
 *  - OWNER      10% (deployer wallet)
 */
contract GAMESBUYSELL is ERC20, ERC20Burnable, Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ---- Fixed wallets (EIP-55 checksummed) ----
    address public constant COMMUNITY_WALLET = 0x8bCf0b66D8c95F60044E4ded8B62C3Ffcefa7f97;
    address public constant LIQUIDITY_WALLET = 0x4e831aAC28F5F4925caD7b5dD81a85bFb21CF218;
    address public constant PRESALE_WALLET   = 0xEeDAb95cb780Fc7a59B6a0e5bBCB5bfb9734189B;
    address public constant GBS_WALLET       = 0xe51F283714B4c745E6185B9BdaFaB25C3C518E2B;

    // ---- Tax (max 10%) + exemptions ----
    uint256 public taxFee = 5;               
    uint256 public constant MIN_TAX_FEE = 0; 
    uint256 public constant MAX_TAX_FEE = 10;

    mapping(address => bool) public isTaxExempt; 
    mapping(address => bool) public isDexPair;   
    mapping(address => bool) public isDexRouter; 

    event TaxFeeChanged(uint256 oldFee, uint256 newFee);
    event TaxExemptUpdated(address indexed account, bool isExempt);
    event DexPairUpdated(address indexed pair, bool isPair);
    event DexRouterUpdated(address indexed router, bool isRouter);
    event NativeWithdraw(address indexed to, uint256 amount);
    event ERC20Rescued(address indexed token, address indexed to, uint256 amount);

    constructor() ERC20("GAMESBUYSELL", "GBS") Ownable(msg.sender) {
        uint256 total = 9_000_000_000 * 10 ** 18;

        // Initial supply distribution
        _mint(PRESALE_WALLET,             (total * 3625) / 10000); // 36.25%
        _mint(LIQUIDITY_WALLET,           (total * 2625) / 10000); // 26.25%
        _mint(GBS_WALLET,                 (total * 1500) / 10000); // 15%
        _mint(COMMUNITY_WALLET,           (total * 1250) / 10000); // 12.5%
        _mint(owner(),                    (total * 1000) / 10000); // 10% (deployer)
    }

    // ---- Management ----
    function setTaxFee(uint256 newTaxFee) external onlyOwner {
        require(newTaxFee >= MIN_TAX_FEE && newTaxFee <= MAX_TAX_FEE, "Tax fee out of bounds");
        uint256 old = taxFee;
        taxFee = newTaxFee;
        emit TaxFeeChanged(old, newTaxFee);
    }

    function setTaxExempt(address account, bool exempt) external onlyOwner {
        require(account != address(0), "Zero address");
        isTaxExempt[account] = exempt;
        emit TaxExemptUpdated(account, exempt);
    }

    function setDexPair(address pair, bool isPair_) external onlyOwner {
        require(pair != address(0), "Zero address");
        isDexPair[pair] = isPair_;
        isTaxExempt[pair] = isPair_; 
        emit DexPairUpdated(pair, isPair_);
    }

    function setDexRouter(address router, bool isRouter_) external onlyOwner {
        require(router != address(0), "Zero address");
        isDexRouter[router] = isRouter_;
        isTaxExempt[router] = isRouter_; 
        emit DexRouterUpdated(router, isRouter_);
    }

    // ---- Transfer with tax ----
    function _update(address from, address to, uint256 amount) internal override {
        address currentOwner = owner();

        bool taxActive = (currentOwner != address(0))
            && (from != currentOwner)
            && (to != currentOwner)
            && (from != address(0))
            && (to != address(0))
            && !isDexPair[from] && !isDexPair[to]
            && !isDexRouter[from] && !isDexRouter[to]
            && !isTaxExempt[from] && !isTaxExempt[to]
            && taxFee > 0;

        if (!taxActive) {
            super._update(from, to, amount);
            return;
        }

        uint256 taxAmount = (amount * taxFee) / 100;
        uint256 netAmount = amount - taxAmount;

        // Distribution of tax:
        //  - 50% liquidity
        //  - 30% burn
        //  - 20% split: GBS_WALLET (5/9) + liquidity (4/9)
        uint256 liqBase     = (taxAmount * 50) / 100;
        uint256 burnPortion = (taxAmount * 30) / 100;
        uint256 partTotal   = (taxAmount * 20) / 100;

        uint256 liqExtra    = (partTotal * 4) / 9;
        uint256 gbsPart     = partTotal - liqExtra;

        super._update(from, LIQUIDITY_WALLET, liqBase + liqExtra);
        super._update(from, address(0),       burnPortion); 
        super._update(from, GBS_WALLET,       gbsPart);
        super._update(from, to,               netAmount);
    }

    // ---- Helpers (protected with ReentrancyGuard) ----
    function withdrawBNB(address payable to, uint256 amount)
        external
        onlyOwner
        nonReentrant
    {
        require(to != address(0), "Zero address");
        require(address(this).balance >= amount, "Insufficient balance");
        (bool ok, ) = to.call{value: amount}("");
        require(ok, "BNB transfer failed");
        emit NativeWithdraw(to, amount);
    }

    function rescueERC20(address token, address to, uint256 amount)
        external
        onlyOwner
        nonReentrant
    {
        require(token != address(0), "Zero token");
        require(to != address(0), "Zero address");
        require(token != address(this), "Cannot rescue GBS");
        IERC20(token).safeTransfer(to, amount);
        emit ERC20Rescued(token, to, amount);
    }

    receive() external payable {}
    fallback() external payable {}

    function renounceOwnership() public override onlyOwner {
        super.renounceOwnership(); // when owner == address(0), tax disables automatically
    }
}
