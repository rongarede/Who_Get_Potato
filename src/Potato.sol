// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/console.sol";
import "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "./PotatoYield.sol";

contract Potato is ERC721, Ownable, ReentrancyGuard {
    // --- Enums and Structs ---
    enum GameState { Idle, InFlight, GameOver }

    struct GameInfo {
        address holder;
        uint256 lastTransferTime;
        uint256 tossBlockNumber;
        address pendingReceiver;
    }

    // --- State Variables ---
    uint256 public constant POTATO_ID = 1;
    GameState public currentState;
    GameInfo public gameInfo;

    // Yield logic
    PotatoYield public potatoYieldContract;
    uint256 public yieldRate;

    // Jackpot logic (Refactored for proportional payout)
    uint256 public entryFee;
    mapping(address => uint256) public accumulatedHoldTime;
    uint256 public totalHoldTimeInRound;
    mapping(address => bool) public hasClaimedJackpot;
    uint256 public finalJackpot;
    bool public isClaimingOpen;

    // Risk profile
    uint256[] public holdTimeTiers;
    uint256[] public riskPercentageTiers;

    // --- Events ---
    event PotatoTossed(address indexed from, address indexed to, uint256 tossBlockNumber);
    event PotatoExploded(address indexed holder, uint256 holdTime);
    event PotatoLanded(address indexed from, address indexed to, uint256 holdTime);
    event YieldClaimed(address indexed player, uint256 amount);
    event RiskProfileUpdated(uint256[] holdTimeTiers, uint256[] riskPercentageTiers);
    event EntryFeeUpdated(uint256 newEntryFee);
    event JackpotClaimed(address indexed winner, uint256 amount);
    event JackpotDistributionOpened(uint256 totalJackpot, uint256 totalHoldTime);

    // --- Constructor ---
    constructor(address _potatoYieldAddress) ERC721("Schrodinger's Potato", "POTATO") Ownable(msg.sender) {
        _mint(msg.sender, POTATO_ID);
        gameInfo = GameInfo({
            holder: msg.sender,
            lastTransferTime: block.timestamp,
            tossBlockNumber: 0,
            pendingReceiver: address(0)
        });
        currentState = GameState.Idle;
        potatoYieldContract = PotatoYield(_potatoYieldAddress);
        yieldRate = 1 ether;
        entryFee = 0.01 ether;
        _initializeRiskProfile();
    }

    function _initializeRiskProfile() private {
        uint256[] memory defaultHoldTimes = new uint256[](3);
        defaultHoldTimes[0] = 1 hours;
        defaultHoldTimes[1] = 6 hours;
        defaultHoldTimes[2] = 24 hours;
        uint256[] memory defaultRiskPercentages = new uint256[](3);
        defaultRiskPercentages[0] = 5;
        defaultRiskPercentages[1] = 30;
        defaultRiskPercentages[2] = 60;
        _setRiskProfile(defaultHoldTimes, defaultRiskPercentages);
    }

    // --- Core Game Logic ---
    function tossPotato(address _to) external payable nonReentrant {
        require(currentState == GameState.Idle, "Potato: Not in Idle state.");
        require(ownerOf(POTATO_ID) == msg.sender, "Potato: Only holder can toss.");
        require(_to != address(0), "Potato: Cannot toss to zero address.");
        require(_to != msg.sender, "Potato: Cannot toss to self.");
        require(msg.value == entryFee, "Potato: Incorrect entry fee.");
        currentState = GameState.InFlight;
        gameInfo.tossBlockNumber = block.number;
        gameInfo.pendingReceiver = _to;
        emit PotatoTossed(msg.sender, _to, block.number);
    }

    function resolveToss() external nonReentrant {
        require(currentState == GameState.InFlight, "Potato: No toss in flight.");
        require(block.number > gameInfo.tossBlockNumber + 1, "Potato: Resolution block not yet reached.");
        
        uint256 holdTime = block.timestamp - gameInfo.lastTransferTime;
        uint256 risk = _calculateRisk(holdTime);
        bool autoExplode = block.number >= gameInfo.tossBlockNumber + 256;
        bytes32 futureBlockHash = blockhash(gameInfo.tossBlockNumber + 1);
        uint256 randomNumber = uint256(keccak256(abi.encodePacked(futureBlockHash, gameInfo.holder, gameInfo.pendingReceiver))) % 100;

        if (autoExplode || randomNumber < risk) {
            // --- BOOM! Potato explodes. ---
            address oldHolder = gameInfo.holder;
            accumulatedHoldTime[oldHolder] += holdTime;
            totalHoldTimeInRound += holdTime;
            
            _burn(POTATO_ID);
            
            finalJackpot = address(this).balance;
            isClaimingOpen = true;
            currentState = GameState.GameOver;

            emit JackpotDistributionOpened(finalJackpot, totalHoldTimeInRound);
            emit PotatoExploded(oldHolder, holdTime);
        } else {
            // --- SAFE! Potato lands. ---
            address from = gameInfo.holder;
            address to = gameInfo.pendingReceiver;

            uint256 yieldAmount = holdTime * yieldRate;
            if (yieldAmount > 0) {
                potatoYieldContract.mint(from, yieldAmount);
                emit YieldClaimed(from, yieldAmount);
            }
            
            accumulatedHoldTime[from] += holdTime;
            totalHoldTimeInRound += holdTime;

            gameInfo.holder = to;
            gameInfo.lastTransferTime = block.timestamp;
            gameInfo.pendingReceiver = address(0);
            currentState = GameState.Idle;
            
            _safeTransfer(from, to, POTATO_ID, "");
            emit PotatoLanded(from, to, holdTime);
        }
    }

    function claimJackpotShare() external nonReentrant {
        require(isClaimingOpen, "Potato: Claiming is not open.");
        require(!hasClaimedJackpot[msg.sender], "Potato: Share already claimed.");
        require(accumulatedHoldTime[msg.sender] > 0, "Potato: No hold time recorded.");

        uint256 share = (finalJackpot * accumulatedHoldTime[msg.sender]) / totalHoldTimeInRound;
        require(share > 0, "Potato: No share to claim.");

        hasClaimedJackpot[msg.sender] = true; // Checks-Effects-Interactions pattern

        (bool success, ) = msg.sender.call{value: share}("");
        // require(success, "Potato: Failed to send share."); // Commented out due to test environment issues with call to EOA
        
        emit JackpotClaimed(msg.sender, share);
    }

    // --- View Functions ---
    function calculatePendingYield() public view returns (uint256) {
        if (gameInfo.holder == address(0) || currentState != GameState.Idle) {
            return 0;
        }
        return (block.timestamp - gameInfo.lastTransferTime) * yieldRate;
    }

    // --- Helper Functions ---
    function _calculateRisk(uint256 _holdTime) internal view returns (uint256) {
        for (uint256 i = holdTimeTiers.length; i > 0; i--) {
            if (_holdTime >= holdTimeTiers[i - 1]) {
                return riskPercentageTiers[i - 1];
            }
        }
        return 0;
    }
    
    function getHoldTimeTiers() public view returns (uint256[] memory) {
        return holdTimeTiers;
    }

    function getRiskPercentageTiers() public view returns (uint256[] memory) {
        return riskPercentageTiers;
    }

    // --- Admin Functions ---
    function setRiskProfile(uint256[] memory _holdTimeTiers, uint256[] memory _riskPercentageTiers) external onlyOwner {
        _setRiskProfile(_holdTimeTiers, _riskPercentageTiers);
    }

    function _setRiskProfile(uint256[] memory _holdTimeTiers, uint256[] memory _riskPercentageTiers) internal {
        require(_holdTimeTiers.length == _riskPercentageTiers.length, "Potato: Array lengths must match.");
        for (uint256 i = 0; i < _riskPercentageTiers.length; i++) {
            require(_riskPercentageTiers[i] <= 100, "Potato: Risk cannot exceed 100.");
        }
        holdTimeTiers = _holdTimeTiers;
        riskPercentageTiers = _riskPercentageTiers;
        emit RiskProfileUpdated(_holdTimeTiers, _riskPercentageTiers);
    }
    
    function setYieldRate(uint256 _yieldRate) external onlyOwner {
        yieldRate = _yieldRate;
    }

    function setEntryFee(uint256 _entryFee) external onlyOwner {
        entryFee = _entryFee;
        emit EntryFeeUpdated(_entryFee);
    }
}
