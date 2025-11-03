// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import "https://github.com/OpenZeppelin/openzeppelin-contracts/blob/master/contracts/token/ERC20/extensions/ERC4626.sol";
import "https://github.com/aerodrome-finance/contracts/blob/main/contracts/interfaces/IRouter.sol";

contract Vault is ERC4626 {

    address public vaultOwner;

    string description;
    uint256 public feeBasisPoints;
    uint256 public slippageTolerance;

    IRouter aeroRouter = IRouter(address(0xcF77a3Ba9A5CA399B7c97c74d54e5b1Beb874E43)); //Aerodrome Router
    address public factory = address(0x5e7BB104d84c7CB9B682AaC2F3d509f5F406809A); //Aerodrome Factory

    //events for EVM logging
    event Deposit(address user, uint256 amount, uint256 minted);
    event Withdraw(address user, uint256 burned);
    event FeeLevelChanged(uint256 oldFeeLevel, uint256 newFeeLevel);
    event UpdatedRouter(address oldRouter, address newRouter);
    event UpdatedFactory(address oldFactory, address newFactory);
    event ChangedOwner(address oldOwner, address newOwner);
    event ChangedSlippage(uint256 oldSlippage, uint256 newSlippage);

    //Errors
    //User tried to do an action he was not allowed to do
    error UnauthorizedActionByAccount(address caller);
    error InvalidFeeBasisPoints(uint256 feeBasisPoints);
    error SameTokenSwap(address tokenIn, address tokenOut);
    error InvalidMultiSwap(uint256 tokensOut, uint256 amountsIn);
    error MultiSwapTooLarge(uint256 numberOfTokens);

    constructor( 
        string memory _name, 
        string memory _symbol,
        string memory _description,
        uint256 _feeBasisPoints,
        uint256 _slippageTolerance) ERC4626(ERC20(0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913)) ERC20(_name, _symbol) {
            description = _description;
            feeBasisPoints = _feeBasisPoints;
            slippageTolerance = _slippageTolerance;
            vaultOwner = msg.sender;
    }

    modifier onlyOwner {
        checkOwner();
        _;
    }

    function checkOwner() internal view {
        if(vaultOwner != _msgSender())
            revert UnauthorizedActionByAccount(_msgSender());
    }

    function setFeeLevel(uint256 _feeBasisPoints) onlyOwner public{
        if(_feeBasisPoints > (5 * (10 ** 16))) //max fee level for all vaults is 5%
            revert InvalidFeeBasisPoints(_feeBasisPoints);

        emit FeeLevelChanged(feeBasisPoints, _feeBasisPoints);
        feeBasisPoints = _feeBasisPoints;
    }

    function updateAerodromeRouter(address newRouter) public onlyOwner {
        emit UpdatedRouter(address(aeroRouter), newRouter);
        aeroRouter = IRouter(newRouter);
    }

    function updateAerodromeFactory(address newFactory) public onlyOwner {
        emit UpdatedFactory(factory, newFactory);
        factory = newFactory;
    }

    function changeOwner(address newOwner) public onlyOwner {
        emit ChangedOwner(vaultOwner, newOwner);
        vaultOwner = newOwner;
    }

    function getAmount(address token, uint256 shares) internal view returns (uint256) {
        return Math.mulDiv(
            IERC20(token).balanceOf(address(this)),  //balance of token in contract
            totalSupply(),  //total supply of vault
            shares  //shares of vault
        );
    }

    /* ============================================================
                Functions for deposit and withdraw
       ============================================================ */

    function deposit(uint256 assets, address receiver) public virtual override  returns (uint256) {
        uint256 maxAssets = maxDeposit(receiver);
        if (assets > maxAssets) {
            revert ERC4626ExceededMaxDeposit(receiver, assets, maxAssets);
        }

        uint256 shares = previewDeposit(assets);
        _deposit(_msgSender(), receiver, assets, shares);
        afterDeposit(assets);

        emit Deposit(_msgSender(), assets, shares);

        return shares;
    }

    /// @inheritdoc IERC4626
    function mint(uint256 shares, address receiver) public virtual override returns (uint256) {
        uint256 maxShares = maxMint(receiver);
        if (shares > maxShares) {
            revert ERC4626ExceededMaxMint(receiver, shares, maxShares);
        }

        uint256 assets = previewMint(shares);
        _deposit(_msgSender(), receiver, assets, shares);
        afterDeposit(assets);

        return assets;
    }

    /// @inheritdoc IERC4626
    function withdraw(uint256 assets, address receiver, address owner) public virtual override returns (uint256) {
        uint256 maxAssets = maxWithdraw(owner);
        if (assets > maxAssets) {
            revert ERC4626ExceededMaxWithdraw(owner, assets, maxAssets);
        }

        uint256 shares = previewWithdraw(assets);
        beforeWithdraw(assets, shares);
        _withdraw(_msgSender(), receiver, owner, assets, shares);

        emit Withdraw(_msgSender(), shares);

        return shares;
    }

    /// @inheritdoc IERC4626
    function redeem(uint256 shares, address receiver, address owner) public virtual override returns (uint256) {
        uint256 maxShares = maxRedeem(owner);
        if (shares > maxShares) {
            revert ERC4626ExceededMaxRedeem(owner, shares, maxShares);
        }

        uint256 assets = previewRedeem(shares);
        beforeWithdraw(assets, shares);
        _withdraw(_msgSender(), receiver, owner, assets, shares);

        return assets;
    }


    /* ============================================================
                Hooks into withdraw and deposit methods
       ============================================================ */
    function afterDeposit(uint256 assets) internal virtual {}
    function beforeWithdraw(uint256 assets, uint256 shares) internal virtual {}

    //swap tokens on Aerodrome
    function swap(address tokenIn, address tokenOut, uint256 amountIn, address receiver) internal returns(uint256[] memory amounts) {
        if(tokenIn == tokenOut) //check if tokenIn and TokenOut are the same
            revert SameTokenSwap(tokenIn, tokenOut);  //revert if they are the same token

        IERC20 ERCToken = IERC20(tokenIn);
        ERCToken.approve(address(aeroRouter), amountIn); //approve router to spend tokens

        //create dynamic array of RouteStruct and add path
        IRouter.Route[] memory routes = new IRouter.Route[](1);
        routes[0] = IRouter.Route(tokenIn, tokenOut, false, factory);
        //amount out from trade
        uint256[] memory returnAmounts = aeroRouter.getAmountsOut(amountIn, routes);

        //execute trade on aerodrome finance
        amounts = aeroRouter.swapExactTokensForTokens(
            amountIn,  //amount of token we want to swap
            returnAmounts[1] * (1e18 - slippageTolerance) / 1e18,  //min amount we want back (- slippage tolerance (e.g. 5 Basis Points (0.5%)))
            routes,  //trade path
            receiver,  //receiver of tokens
            block.timestamp + 300 //deadline for trade
        );
        return amounts;
    }

    function validateSwap(uint256 tokens, uint256 amounts) internal pure {
        if(tokens > 10) //check if tokens is greater than 10
            revert MultiSwapTooLarge(tokens); //revert if tokens is greater than 10 (arbitrary limit to prevent gas issues)
        
        if(tokens != amounts) //check if tokens and amounts are the same length
            revert InvalidMultiSwap(tokens, amounts); //revert if they are not the same length
    }

    function swapFromTokenToTokens(address tokenIn, address[] memory tokensOut, uint256[] memory amountsIn) internal returns(uint256[] memory amountOut){
        uint tokensOutLength = tokensOut.length;
        uint amountsInLength = amountsIn.length;
        
        validateSwap(tokensOutLength, amountsInLength); //validate swap
        
        for(uint i = 0; i < tokensOutLength; ++i) {
            amountOut[i] = swap(tokenIn, tokensOut[i], amountsIn[i], address(this))[1];
        }
    }
    
    function swapFromTokensToToken(address[] memory tokensIn, address tokenOut, uint256[] memory amountsIn) internal returns(uint256 amountOut) {
        uint tokensInLength = tokensIn.length;
        uint amountsInLength = amountsIn.length;
        validateSwap(tokensInLength, amountsInLength); //validate swap
        

        for(uint i = 0; i < tokensInLength; ++i) {
            amountOut += swap(tokensIn[i], tokenOut, amountsIn[i], address(this))[1];
        }
    }
}