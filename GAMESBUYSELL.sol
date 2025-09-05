
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/* OpenZeppelin v5.4.0 raw imports (Remix uyumlu) */
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
 * Vergi: varsayılan %5 (min 0, max 10); owner/pair/router/muaf adreslerde vergi yok.
 * Dağıtım (deploy anında):
 *  - PRESALE    36.25%
 *  - LIQUIDITY  26.25%
 *  - GBS_WALLET 15%
 *  - COMMUNITY  12.5%
 *  - OWNER      10%  (deploy eden cüzdan)
 */
contract GAMESBUYSELL is ERC20, ERC20Burnable, Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ---- Sabit cüzdanlar (EIP-55 checksummed) ----
    address public constant COMMUNITY_WALLET = 0x8bCf0b66D8c95F60044E4ded8B62C3Ffcefa7f97;
    address public constant LIQUIDITY_WALLET = 0x4e831aAC28F5F4925caD7b5dD81a85bFb21CF218;
    address public constant PRESALE_WALLET   = 0xEeDAb95cb780Fc7a59B6a0e5bBCB5bfb9734189B;
    address public constant GBS_WALLET       = 0xe51F283714B4c745E6185B9BdaFaB25C3C518E2B;

    // ---- Vergi (max %10) + muafiyetler ----
    uint256 public taxFee = 5;               // %5 başlangıç
    uint256 public constant MIN_TAX_FEE = 0; // 0 = vergi kapatılabilir
    uint256 public constant MAX_TAX_FEE = 10;// üst sınır %10

    mapping(address => bool) public isTaxExempt; // oracle, borsalar, vb.
    mapping(address => bool) public isDexPair;   // Pancake/DEX pair
    mapping(address => bool) public isDexRouter; // Router (PCS v2/v3, vs.)

    event TaxFeeChanged(uint256 oldFee, uint256 newFee);
    event TaxExemptUpdated(address indexed account, bool isExempt);
    event DexPairUpdated(address indexed pair, bool isPair);
    event DexRouterUpdated(address indexed router, bool isRouter);
    event NativeWithdraw(address indexed to, uint256 amount);
    event ERC20Rescued(address indexed token, address indexed to, uint256 amount);

    constructor() ERC20("GAMESBUYSELL", "GBS") Ownable(msg.sender) {
        uint256 total = 9_000_000_000 * 10 ** 18;

        // Deploy dağıtımı
        _mint(PRESALE_WALLET,             (total * 3625) / 10000); // 36.25%
        _mint(LIQUIDITY_WALLET,           (total * 2625) / 10000); // 26.25%
        _mint(GBS_WALLET,                 (total * 1500) / 10000); // 15%
        _mint(COMMUNITY_WALLET,           (total * 1250) / 10000); // 12.5%
        _mint(owner(),                    (total * 1000) / 10000); // 10% (deploy cüzdanı)
    }

    // ---- Yönetim ----
    function setTaxFee(uint256 _taxFee) external onlyOwner {
        require(_taxFee >= MIN_TAX_FEE && _taxFee <= MAX_TAX_FEE, "Tax fee out of bounds");
        uint256 old = taxFee;
        taxFee = _taxFee;
        emit TaxFeeChanged(old, _taxFee);
    }

    function setTaxExempt(address account, bool exempt) external onlyOwner {
        isTaxExempt[account] = exempt;
        emit TaxExemptUpdated(account, exempt);
    }

    function setDexPair(address pair, bool isPair_) external onlyOwner {
        isDexPair[pair] = isPair_;
        isTaxExempt[pair] = isPair_; // pair vergiden muaf
        emit DexPairUpdated(pair, isPair_);
    }

    function setDexRouter(address router, bool isRouter_) external onlyOwner {
        isDexRouter[router] = isRouter_;
        isTaxExempt[router] = isRouter_; // router vergiden muaf
        emit DexRouterUpdated(router, isRouter_);
    }

    // ---- Transfer vergisi ----
    function _update(address from, address to, uint256 amount) internal override {
        address _owner = owner();

        // Mint/Burn vergisiz; owner renounce edilirse vergi kapanır
        bool taxActive = (_owner != address(0))
            && (from != _owner)
            && (to != _owner)
            && (from != address(0))
            && (to != address(0))
            // DEX çiftleri/route ve muaf adreslere vergi yok
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

        // %5 vergi dağılımı:
        //  - %50 likidite
        //  - %30 burn
        //  - %20: GBS_WALLET (5/9) + ek likidite (4/9)
        uint256 liqBase     = (taxAmount * 50) / 100;
        uint256 burnPortion = (taxAmount * 30) / 100;
        uint256 partTotal   = (taxAmount * 20) / 100;

        uint256 liqExtra    = (partTotal * 4) / 9;
        uint256 gbsPart     = partTotal - liqExtra;

        super._update(from, LIQUIDITY_WALLET, liqBase + liqExtra);
        super._update(from, address(0),       burnPortion); // burn (zero address)
        super._update(from, GBS_WALLET,       gbsPart);
        super._update(from, to,               netAmount);
    }

    // ---- Reentrancy korumalı yardımcılar ----
    function withdrawBNB(address payable to, uint256 amount)
        external
        onlyOwner
        nonReentrant
    {
        require(to != address(0), "zero addr");
        require(address(this).balance >= amount, "insufficient");
        (bool ok, ) = to.call{value: amount}("");
        require(ok, "BNB transfer failed");
        emit NativeWithdraw(to, amount);
    }

    function rescueERC20(address token, address to, uint256 amount)
        external
        onlyOwner
        nonReentrant
    {
        require(token != address(0), "zero token");
        require(to != address(0), "zero addr");
        require(token != address(this), "cannot rescue GBS");
        IERC20(token).safeTransfer(to, amount);
        emit ERC20Rescued(token, to, amount);
    }

    receive() external payable {}
    fallback() external payable {}

    function renounceOwnership() public override onlyOwner {
        super.renounceOwnership(); // owner == address(0) → vergi kapanır
    }
}
