// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

contract MockAggregatorV3 {
    uint8 public decimals = 8;
    string public description = "Mock Price Feed";
    uint256 public version = 1;
    
    int256 private price;
    uint256 private updatedAt;
    
    function setPrice(int256 _price) external {
        price = _price;
        updatedAt = block.timestamp;
    }
    
    function latestRoundData() external view returns (
        uint80 roundId,
        int256 answer,
        uint256 startedAt,
        uint256 updatedAtTime,
        uint80 answeredInRound
    ) {
        return (1, price, updatedAt, updatedAt, 1);
    }
    
    function latestAnswer() external view returns (int256) {
        return price;
    }
}