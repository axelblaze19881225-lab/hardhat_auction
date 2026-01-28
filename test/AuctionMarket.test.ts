const { expect } = require("chai");
const { ethers, upgrades } = require("hardhat");
const helpers = require("@nomicfoundation/hardhat-network-helpers");

const { parseEther, ZeroAddress, MaxUint256 } = ethers;

describe("NFT Auction Market", function () {
  // 添加类型注解
  let nft: any;
  let auctionMarket: any;
  let mockERC20: any;
  let mockPriceFeed: any;
  
  let owner: any;
  let seller: any;
  let bidder1: any;
  let bidder2: any;
  let feeWallet: any;

  const NFT_NAME = "MyNFT";
  const NFT_SYMBOL = "MNFT";
  const DURATION = 7 * 24 * 60 * 60; // 7 days
  const RESERVE_PRICE = parseEther("1");
  const FEE_PERCENTAGE = 250; // 2.5%

  beforeEach(async function () {
    [owner, seller, bidder1, bidder2, feeWallet] = await ethers.getSigners();

    // Deploy Mock ERC20
    const MockERC20 = await ethers.getContractFactory("MockERC20");
    mockERC20 = await MockERC20.deploy("Test Token", "TEST");
    await mockERC20.waitForDeployment();
    
    // Deploy Mock Price Feed
    const MockPriceFeed = await ethers.getContractFactory("MockAggregatorV3");
    mockPriceFeed = await MockPriceFeed.deploy();
    await mockPriceFeed.waitForDeployment();
    await mockPriceFeed.setPrice(3000 * 10 ** 8); // $3000

    // Deploy NFT
    const NFT = await ethers.getContractFactory("MyNFT");
    nft = await NFT.deploy();
    await nft.waitForDeployment();

    // Deploy Auction Market (UUPS)
    const AuctionMarket = await ethers.getContractFactory("AuctionMarketV1");
    auctionMarket = await upgrades.deployProxy(
      AuctionMarket,
      [
        await mockPriceFeed.getAddress(),
        feeWallet.address,
        FEE_PERCENTAGE
      ],
      { kind: 'uups' }
    );
    await auctionMarket.waitForDeployment();

    // Mint some NFTs
    await nft.connect(seller).safeMint(seller.address, "ipfs://token1");
    await nft.connect(seller).safeMint(seller.address, "ipfs://token2");
    
    // Approve auction market
    await nft.connect(seller).setApprovalForAll(await auctionMarket.getAddress(), true);
    
    // Mint ERC20 tokens for bidders
    await mockERC20.mint(bidder1.address, parseEther("1000"));
    await mockERC20.mint(bidder2.address, parseEther("1000"));
  });

  describe("Deployment", function () {
    it("Should deploy NFT with correct name and symbol", async function () {
      expect(await nft.name()).to.equal(NFT_NAME);
      expect(await nft.symbol()).to.equal(NFT_SYMBOL);
    });

    it("Should deploy AuctionMarket with correct initial state", async function () {
      expect(await auctionMarket.owner()).to.equal(owner.address);
      expect(await auctionMarket.feeWallet()).to.equal(feeWallet.address);
      expect(await auctionMarket.feePercentage()).to.equal(FEE_PERCENTAGE);
    });
  });

  describe("Auction Creation", function () {
    it("Should create ETH auction successfully", async function () {
      const tx = await auctionMarket.connect(seller).createAuction(
        await nft.getAddress(),
        0,
        DURATION,
        RESERVE_PRICE,
        0, // ETH
        ZeroAddress
      );
      
      const receipt = await tx.wait();
      
      // 检查 AuctionCreated 事件
      const eventFragment = auctionMarket.interface.getEvent("AuctionCreated");
      const eventTopic = auctionMarket.interface.getEventTopic(eventFragment);
      const eventLog = receipt.logs.find((log: any) => log.topics[0] === eventTopic);
      expect(eventLog).to.not.be.undefined;
      
      const auction = await auctionMarket.auctions(1);
      expect(auction.seller).to.equal(seller.address);
      expect(auction.reservePrice).to.equal(RESERVE_PRICE);
      expect(auction.paymentToken).to.equal(0); // ETH
      expect(auction.status).to.equal(0); // Active
    });
  });
});