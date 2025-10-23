// SPDX-License-Identifier: GPL-3.0

//0.0001% = 1 Basis Point
//1% = 10,000 Basis Points
//100% = 1,000,000 Basis Points

pragma solidity 0.8.30;

import "https://github.com/OpenZeppelin/openzeppelin-contracts/blob/master/contracts/token/ERC20/extensions/ERC4626.sol";
import "https://github.com/aerodrome-finance/contracts/blob/main/contracts/interfaces/IRouter.sol";
import "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";

/*
    This is a vault contract that allows users to deposit and withdraw tokens.
    It is an ERC4626 token contract that allows users to deposit and withdraw tokens.
    It is a non-reentrant contract that allows users to deposit and withdraw tokens.
    It is a pausable contract that allows users to deposit and withdraw tokens.
    It is a burnable contract that allows users to deposit and withdraw tokens.
    It is a mintable contract that allows users to deposit and withdraw tokens

    Formula to calculate share value: (Total Value Locked)/(Total Shares)
    Formula to calculate return amount of token: (Total Token Balance)/(Total Shares)
    Protocol Fee (on deposit): 0,02% (200 Basis Points)
*/

contract Vault is ERC4626 {

    string public VaultName;
    string public description;
    address public vaultOwner;
    address public principalToken;
    uint256 slippageTolerance;
    uint256 public entryFeeBasisPoints;
    AggregatorV3Interface internal dataFeed = AggregatorV3Interface(0x694AA1769357215DE4FAC081bf1f309aDC325306); //ChainLink Oracle for Prices

    IRouter constant aeroRouter = IRouter(address(0xcF77a3Ba9A5CA399B7c97c74d54e5b1Beb874E43)); //Aerodrome Router
    address public constant factory = address(0x5e7BB104d84c7CB9B682AaC2F3d509f5F406809A); //Aerodrome Factory

    struct Token {
        address token;
        uint256 weight;
    }

    Token[] tokens;

    constructor(
        address _asset,
        string memory _name,
        string memory _symbol,
        string memory _description,
        Token[] memory _tokens,
        uint256 _slippageTolerance,
        uint256 _entryFeeBasisPoints
    ) ERC4626(ERC20(_asset)) ERC20(_name, _symbol) {
        require(_slippageTolerance <= 50, "Slippage Tolerance must be less than or equal to 5%");
        description = _description; //set description of vault
        vaultOwner = msg.sender; //set creator as owner of vault
        principalToken = _asset; //define principal token
        slippageTolerance = _slippageTolerance; //set slippage tolerance
        entryFeeBasisPoints = _entryFeeBasisPoints; //set entry fee
        principalToken = _asset; //set principal token

        registerTokens(_tokens);

        SafeERC20.safeTransfer(IERC20(_asset), msg.sender, 1);
    }

    // Registers tokens in the vault and ensures that the weights sum up to 100%
    function registerTokens(Token[] memory _tokens) internal {
        uint length = _tokens.length;
        require(length <= 15, "Vault can hold a maximum of 15 tokens");

        uint256 sum = 0;
        for(uint i = 0; i < length;) {
            Token memory token = _tokens[i];
            require(token.weight > 0, "Weight of a token cannot be zero");

            tokens.push(token);
            sum += token.weight;

            unchecked {
                ++i;
            }
        }

        require(sum == 1e18, "Weights of tokens must sum up to 100%");
    }

    /* ////////////////////////////////////////////////////////////////////////////
                        Fee Logic for Deposit and mint
       //////////////////////////////////////////////////////////////////////////// */

    function previewDeposit(uint256 assets) public view override returns (uint256) {
        uint256 fee = _feeOnTotal(assets);
        return super.previewDeposit(assets - fee);
    }

    function previewMint(uint256 shares) public view override returns (uint256) {
        uint256 assets = super.previewMint(shares);
        return assets + _feeOnRaw(assets);
    }

    function _feeOnTotal(uint256 assets) private pure returns (uint256) {
        return Math.mulDiv(assets, 200, 20 + (10 ** 6), Math.Rounding.Ceil);
    }

    function _feeOnRaw(uint256 assets) private pure returns (uint256) {
        return Math.mulDiv(assets, 200, 10 ** 6, Math.Rounding.Ceil);
    }

    function _deposit(address caller, address receiver, uint256 assets, uint256 shares) internal override {
        uint256 fee = _feeOnTotal(assets);

        super._deposit(caller, receiver, assets, shares);
        if(fee > 0)
            SafeERC20.safeTransfer(IERC20(principalToken), vaultOwner, fee);
    } 

    /*  ////////////////////////////////////////////////////////////////////////////
                        Logic to get balance for smart contract
        //////////////////////////////////////////////////////////////////////////// */
    function getTokenValue(address token) public view returns(uint256) {
        //TODO: Implement Aerodrome Finance Spot Price Method (to get Spot Price for Token Pair [Token & Principal Token])
        uint256 price = 1;
        return IERC20(token).balanceOf(address(this)) * price;
    }

    function totalAssets() public view override returns(uint256) {
        uint256 total;
        uint length = tokens.length;

        for(uint i = 0; i < length;) {
            total += getTokenValue(tokens[i].token);
            unchecked {
                ++i;
            }
        }

        return total;
    }

    
    /*  ////////////////////////////////////////////////////////////////////////////
                    Hooks into withdraw and deposit methods
    //////////////////////////////////////////////////////////////////////////// */

    function beforeWithdraw(uint256 assets, uint256 shares) internal {
        uint length = tokens.length;
        address mPrincipalToken = principalToken; //load principalToken from storage into memory
        for(uint i = 0; i < length;) {
            address token = tokens[i].token;
            if(token == principalToken) {
                uint256 amount = Math.mulDiv(IERC20(token).balanceOf(address(this)), totalSupply(), shares, Math.Rounding.Ceil);
                //uint256 amount = IERC20(token).balanceOf(address(this)) / totalSupply() * shares; //amount of principalToken to pay out
                SafeERC20.safeTransfer(IERC20(mPrincipalToken), msg.sender, amount);
            } else {
                uint256 amount = IERC20(token).balanceOf(address(this)) / totalSupply() * shares; //amount of token 'token' to pay out
                swap(token, mPrincipalToken, amount, msg.sender);
            }
                
            unchecked {
                ++i;
            }
        }
    }
    
    function afterDeposit(uint256 assets) internal {
        uint length = tokens.length;
        address mPrincipalToken = principalToken; //load principalToken from storage into memory
        for(uint i = 0; i < length;) {
            Token memory tokenStruct = tokens[i];
            address token = tokenStruct.token;
            if(token == principalToken) {
                uint256 amount = assets * tokenStruct.weight;
                SafeERC20.safeTransfer(IERC20(mPrincipalToken), address(this), amount);
            } else {
                swap(mPrincipalToken, token, assets, address(this));
            }

            unchecked {
                ++i;
            }
        }
    }

    /*  ////////////////////////////////////////////////////////////////////////////
                    mint, deposit, withdraw, redeem methods
    //////////////////////////////////////////////////////////////////////////// */

    function deposit(uint256 assets, address receiver) public virtual override  returns (uint256) {
        uint256 maxAssets = maxDeposit(receiver);
        if (assets > maxAssets) {
            revert ERC4626ExceededMaxDeposit(receiver, assets, maxAssets);
        }

        uint256 shares = previewDeposit(assets);
        _deposit(_msgSender(), receiver, assets, shares);
        afterDeposit(assets);

        return shares;
    }

    /// @inheritdoc IERC4626
    function mint(uint256 shares, address receiver) public virtual override returns (uint256) {
        uint256 maxShares = maxMint(receiver);
        if (shares > maxShares) {
            revert ERC4626ExceededMaxMint(receiver, shares, maxShares);
        }

        uint256 assets = previewMint(shares);
        beforeWithdraw(assets, shares);
        _deposit(_msgSender(), receiver, assets, shares);

        return assets;
    }

    /// @inheritdoc IERC4626
    function withdraw(uint256 assets, address receiver, address owner) public virtual override returns (uint256) {
        uint256 maxAssets = maxWithdraw(owner);
        if (assets > maxAssets) {
            revert ERC4626ExceededMaxWithdraw(owner, assets, maxAssets);
        }

        uint256 shares = previewWithdraw(assets);
        _withdraw(_msgSender(), receiver, owner, assets, shares);

        return shares;
    }

    /// @inheritdoc IERC4626
    function redeem(uint256 shares, address receiver, address owner) public virtual override returns (uint256) {
        uint256 maxShares = maxRedeem(owner);
        if (shares > maxShares) {
            revert ERC4626ExceededMaxRedeem(owner, shares, maxShares);
        }

        uint256 assets = previewRedeem(shares);
        _withdraw(_msgSender(), receiver, owner, assets, shares);

        return assets;
    }

    /*  ////////////////////////////////////////////////////////////////////////////
                    Logic to swap tokens on Aerodrome Finance
    //////////////////////////////////////////////////////////////////////////// */

    function swap(address tokenIn, address tokenOut, uint256 amountIn, address receiver) internal returns(uint256[] memory amounts) {
        //tokens are already in contract --> no need to transfer them
        IERC20 tokenInERC20 = IERC20(tokenIn);
        
        //approve router to spend tokens
        tokenInERC20.approve(address(aeroRouter), amountIn);

        //create dynamic array of RouteStruct and add path
        IRouter.Route[] memory routes = new IRouter.Route[](1);
        routes[0] = IRouter.Route(tokenIn, tokenOut, false, factory);
        //amount out from trade
        uint256[] memory returnAmounts = aeroRouter.getAmountsOut(amountIn, routes);

        //execute trade on aerodrome finance
        amounts = aeroRouter.swapExactTokensForTokens(
            amountIn,  //amount of token we want to swap
            returnAmounts[1] * (1000 - slippageTolerance) / 1000,  //min amount we want back (- slippage tolerance (e.g. 5 Basis Points (0.5%)))
            routes,  //trade path
            receiver,  //receiver of tokens
            block.timestamp + 30 //deadline for trade
        );
        return amounts;
    }

    /*  ////////////////////////////////////////////////////////////////////////////
                    Logic to modify vault settings
    //////////////////////////////////////////////////////////////////////////// */
    function transferOwnership(address newOwner) public onlyOwner {
        vaultOwner = newOwner;
    }

    function setSlippage(uint256 slippage) public onlyOwner {
        slippageTolerance = slippage;
    }

    function setEntryFee(uint256 fee) public onlyOwner {
        entryFeeBasisPoints = fee;
    }

    modifier onlyOwner {
        require(msg.sender == vaultOwner, "Only the vault owner can access this function");
        _;
    }
}