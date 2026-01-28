import { buildModule } from "@nomicfoundation/hardhat-ignition/modules";

const SEPOLIA_PRICE_FEEDS = {
  ETH_USD: "0x694AA1769357215DE4FAC081bf1f309aDC325306",
  LINK_USD: "0xc59E3633BAAC79493d908e63626716e204A45EdF"
};

const AuctionMarketModule = buildModule("AuctionMarketModule", (m) => {
  // Get deployer account
  const deployer = m.getAccount(0);
  
  // Deploy MyNFT
  const nft = m.contract("MyNFT", [], {
    from: deployer,
  });
  
  // Deploy AuctionMarketV1 implementation
  const auctionMarket = m.contract("AuctionMarketV1", [], {
    from: deployer,
  });
  
  // Initialize AuctionMarket
  m.call(auctionMarket, "initialize", [
    SEPOLIA_PRICE_FEEDS.ETH_USD,
    deployer, // fee wallet
    250 // 2.5% fee
  ], {
    from: deployer,
    after: [auctionMarket]
  });
  
  return { nft, auctionMarket };
});

export default AuctionMarketModule;