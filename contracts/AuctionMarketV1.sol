// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";

contract AuctionMarketV1 is Initializable, OwnableUpgradeable, UUPSUpgradeable {
    using SafeERC20 for IERC20;
    
    enum AuctionStatus { Active, Ended, Cancelled }
    enum PaymentToken { ETH, ERC20 }
    
    struct Auction {
        uint256 auctionId;
        address seller;
        address nftContract;
        uint256 tokenId;
        uint256 startTime;
        uint256 endTime;
        uint256 reservePrice; // in wei or token units
        PaymentToken paymentToken;
        address erc20Token; // address(0) for ETH
        address highestBidder;
        uint256 highestBid;
        AuctionStatus status;
    }
    
    uint256 public auctionCount;
    uint256 public feePercentage; // basis points (100 = 1%)
    address public feeWallet;
    
    // Chainlink Price Feeds
    address public ethUsdPriceFeed;
    mapping(address => address) public erc20UsdPriceFeeds;
    
    // Mappings
    mapping(uint256 => Auction) public auctions;
    mapping(address => mapping(uint256 => uint256)) public tokenIdToAuctionId;
    mapping(address => mapping(uint256 => uint256)) public pendingReturns;
    
    event AuctionCreated(
        uint256 indexed auctionId,
        address indexed seller,
        address nftContract,
        uint256 tokenId,
        uint256 startTime,
        uint256 endTime,
        uint256 reservePrice,
        PaymentToken paymentToken,
        address erc20Token
    );
    
    event BidPlaced(
        uint256 indexed auctionId,
        address indexed bidder,
        uint256 amount,
        uint256 amountInUsd
    );
    
    event AuctionEnded(
        uint256 indexed auctionId,
        address indexed winner,
        uint256 winningBid,
        uint256 sellerAmount,
        uint256 feeAmount
    );
    
    event AuctionCancelled(uint256 indexed auctionId);
    event PriceFeedUpdated(address indexed token, address priceFeed);
    
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }
    
    function initialize(
        address _ethUsdPriceFeed,
        address _feeWallet,
        uint256 _feePercentage
    ) public initializer {
        __Ownable_init(msg.sender);
        __UUPSUpgradeable_init();
        
        ethUsdPriceFeed = _ethUsdPriceFeed;
        feeWallet = _feeWallet;
        feePercentage = _feePercentage;
        auctionCount = 0;
    }
    
    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}
    
    // Price feed functions
    function setEthUsdPriceFeed(address _priceFeed) external onlyOwner {
        ethUsdPriceFeed = _priceFeed;
    }
    
    function setERC20UsdPriceFeed(address _erc20Token, address _priceFeed) external onlyOwner {
        erc20UsdPriceFeeds[_erc20Token] = _priceFeed;
        emit PriceFeedUpdated(_erc20Token, _priceFeed);
    }
    
    function getLatestPrice(address priceFeed) public view returns (int256) {
        require(priceFeed != address(0), "Price feed not set");
        AggregatorV3Interface priceFeedContract = AggregatorV3Interface(priceFeed);
        (, int256 price, , , ) = priceFeedContract.latestRoundData();
        return price;
    }
    
    function convertToUsd(uint256 amount, PaymentToken paymentToken, address erc20Token) 
        public 
        view 
        returns (uint256) 
    {
        address priceFeed;
        
        if (paymentToken == PaymentToken.ETH) {
            priceFeed = ethUsdPriceFeed;
        } else {
            priceFeed = erc20UsdPriceFeeds[erc20Token];
        }
        
        require(priceFeed != address(0), "Price feed not available");
        
        int256 price = getLatestPrice(priceFeed);
        require(price > 0, "Invalid price");
        
        // Price has 8 decimals in Chainlink, amount has 18 decimals for ETH/ERC20
        // Convert to 18 decimal USD amount
        return (amount * uint256(price) * 1e10) / 1e18;
    }
    
    // Auction functions
    function createAuction(
        address _nftContract,
        uint256 _tokenId,
        uint256 _duration,
        uint256 _reservePrice,
        PaymentToken _paymentToken,
        address _erc20Token
    ) external returns (uint256) {
        require(_duration > 0, "Duration must be > 0");
        require(_reservePrice > 0, "Reserve price must be > 0");
        
        IERC721 nft = IERC721(_nftContract);
        require(nft.ownerOf(_tokenId) == msg.sender, "Not NFT owner");
        require(nft.getApproved(_tokenId) == address(this) || 
                nft.isApprovedForAll(msg.sender, address(this)), "Not approved");
        
        require(tokenIdToAuctionId[_nftContract][_tokenId] == 0, "NFT already in auction");
        
        uint256 auctionId = ++auctionCount;
        uint256 startTime = block.timestamp;
        uint256 endTime = startTime + _duration;
        
        auctions[auctionId] = Auction({
            auctionId: auctionId,
            seller: msg.sender,
            nftContract: _nftContract,
            tokenId: _tokenId,
            startTime: startTime,
            endTime: endTime,
            reservePrice: _reservePrice,
            paymentToken: _paymentToken,
            erc20Token: _erc20Token,
            highestBidder: address(0),
            highestBid: 0,
            status: AuctionStatus.Active
        });
        
        tokenIdToAuctionId[_nftContract][_tokenId] = auctionId;
        
        nft.transferFrom(msg.sender, address(this), _tokenId);
        
        emit AuctionCreated(
            auctionId,
            msg.sender,
            _nftContract,
            _tokenId,
            startTime,
            endTime,
            _reservePrice,
            _paymentToken,
            _erc20Token
        );
        
        return auctionId;
    }
    
    function bid(uint256 _auctionId, uint256 _amount) external payable {
        Auction storage auction = auctions[_auctionId];
        
        require(auction.status == AuctionStatus.Active, "Auction not active");
        require(block.timestamp < auction.endTime, "Auction ended");
        require(block.timestamp >= auction.startTime, "Auction not started");
        
        uint256 bidAmount;
        if (auction.paymentToken == PaymentToken.ETH) {
            require(msg.value == _amount, "ETH amount mismatch");
            bidAmount = msg.value;
        } else {
            require(msg.value == 0, "ETH not accepted");
            require(_amount > 0, "Invalid bid amount");
            bidAmount = _amount;
            
            IERC20 token = IERC20(auction.erc20Token);
            require(token.balanceOf(msg.sender) >= bidAmount, "Insufficient balance");
            require(token.allowance(msg.sender, address(this)) >= bidAmount, "Insufficient allowance");
            
            token.safeTransferFrom(msg.sender, address(this), bidAmount);
        }
        
        require(bidAmount > auction.highestBid, "Bid too low");
        require(bidAmount >= auction.reservePrice, "Below reserve price");
        
        // Return previous highest bid
        if (auction.highestBidder != address(0)) {
            pendingReturns[auction.highestBidder][_auctionId] += auction.highestBid;
        }
        
        auction.highestBid = bidAmount;
        auction.highestBidder = msg.sender;
        
        uint256 amountInUsd = convertToUsd(bidAmount, auction.paymentToken, auction.erc20Token);
        
        emit BidPlaced(_auctionId, msg.sender, bidAmount, amountInUsd);
    }
    
    function endAuction(uint256 _auctionId) external {
        Auction storage auction = auctions[_auctionId];
        
        require(auction.status == AuctionStatus.Active, "Auction not active");
        require(block.timestamp >= auction.endTime || msg.sender == auction.seller, "Cannot end early");
        require(auction.highestBidder != address(0), "No bids");
        
        auction.status = AuctionStatus.Ended;
        
        // Calculate fees
        uint256 feeAmount = (auction.highestBid * feePercentage) / 10000;
        uint256 sellerAmount = auction.highestBid - feeAmount;
        
        // Transfer NFT to winner
        IERC721(auction.nftContract).transferFrom(
            address(this), 
            auction.highestBidder, 
            auction.tokenId
        );
        
        // Transfer funds
        if (auction.paymentToken == PaymentToken.ETH) {
            payable(auction.seller).transfer(sellerAmount);
            payable(feeWallet).transfer(feeAmount);
        } else {
            IERC20 token = IERC20(auction.erc20Token);
            token.safeTransfer(auction.seller, sellerAmount);
            token.safeTransfer(feeWallet, feeAmount);
        }
        
        // Clean up
        delete tokenIdToAuctionId[auction.nftContract][auction.tokenId];
        
        emit AuctionEnded(
            _auctionId,
            auction.highestBidder,
            auction.highestBid,
            sellerAmount,
            feeAmount
        );
    }
    
    function cancelAuction(uint256 _auctionId) external {
        Auction storage auction = auctions[_auctionId];
        
        require(auction.status == AuctionStatus.Active, "Auction not active");
        require(msg.sender == auction.seller || msg.sender == owner(), "Not authorized");
        require(auction.highestBidder == address(0), "Bids already placed");
        
        auction.status = AuctionStatus.Cancelled;
        
        // Return NFT to seller
        IERC721(auction.nftContract).transferFrom(
            address(this), 
            auction.seller, 
            auction.tokenId
        );
        
        delete tokenIdToAuctionId[auction.nftContract][auction.tokenId];
        
        emit AuctionCancelled(_auctionId);
    }
    
    function withdrawPendingReturn(uint256 _auctionId) external {
        uint256 amount = pendingReturns[msg.sender][_auctionId];
        require(amount > 0, "No pending return");
        
        pendingReturns[msg.sender][_auctionId] = 0;
        
        Auction storage auction = auctions[_auctionId];
        if (auction.paymentToken == PaymentToken.ETH) {
            payable(msg.sender).transfer(amount);
        } else {
            IERC20(auction.erc20Token).safeTransfer(msg.sender, amount);
        }
    }
    
    function getAuctionDetails(uint256 _auctionId) 
        external 
        view 
        returns (
            Auction memory,
            uint256 currentBidInUsd
        ) 
    {
        Auction memory auction = auctions[_auctionId];
        uint256 usdAmount = 0;
        
        if (auction.highestBid > 0) {
            usdAmount = convertToUsd(
                auction.highestBid, 
                auction.paymentToken, 
                auction.erc20Token
            );
        }
        
        return (auction, usdAmount);
    }
    
    function getActiveAuctions() external view returns (Auction[] memory) {
        uint256 activeCount = 0;
        
        for (uint256 i = 1; i <= auctionCount; i++) {
            if (auctions[i].status == AuctionStatus.Active) {
                activeCount++;
            }
        }
        
        Auction[] memory activeAuctions = new Auction[](activeCount);
        uint256 index = 0;
        
        for (uint256 i = 1; i <= auctionCount; i++) {
            if (auctions[i].status == AuctionStatus.Active) {
                activeAuctions[index] = auctions[i];
                index++;
            }
        }
        
        return activeAuctions;
    }
    
    // For testing and emergency
    function emergencyWithdrawNFT(
        address _nftContract, 
        uint256 _tokenId, 
        address _to
    ) external onlyOwner {
        require(tokenIdToAuctionId[_nftContract][_tokenId] == 0, "NFT in auction");
        
        IERC721 nft = IERC721(_nftContract);
        require(nft.ownerOf(_tokenId) == address(this), "NFT not owned by contract");
        
        nft.transferFrom(address(this), _to, _tokenId);
    }
    
    receive() external payable {}
}