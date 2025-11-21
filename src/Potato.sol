// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/console.sol";
import "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/**
 * @title Schrodinger's Potato
 * @author Gemini
 * @notice A probabilistic game based on delayed settlement of block hashes.
 * The "Potato" is a single ERC721 token (tokenId 1).
 */
contract Potato is ERC721, Ownable, ReentrancyGuard {
    // --- Enums and Structs ---

    enum GameState {
        Idle,
        InFlight
    }

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

    // Risk profile: holdTimeTiers[i] seconds -> riskPercentageTiers[i]% chance of explosion
    uint256[] public holdTimeTiers;
    uint256[] public riskPercentageTiers;

    // --- Events ---

    event PotatoTossed(
        address indexed from,
        address indexed to,
        uint256 tossBlockNumber
    );
    event PotatoExploded(address indexed holder, uint256 holdTime);
    event PotatoLanded(
        address indexed from,
        address indexed to,
        uint256 holdTime
    );
    event YieldClaimed(address indexed player, uint256 amount);
    event RiskProfileUpdated(
        uint256[] holdTimeTiers,
        uint256[] riskPercentageTiers
    );

    // --- Constructor ---

    constructor() ERC721("Schrodinger's Potato", "POTATO") Ownable(msg.sender) {
        _mint(msg.sender, POTATO_ID);

        gameInfo = GameInfo({
            holder: msg.sender,
            lastTransferTime: block.timestamp,
            tossBlockNumber: 0,
            pendingReceiver: address(0)
        });
        currentState = GameState.Idle;

        // Default risk profile:
        // - 1-6 hours: 5%
        // - 6-24 hours: 30%
        // - >24 hours: 60%
        uint256[] memory defaultHoldTimes = new uint256[](3);
        defaultHoldTimes[0] = 1 hours;
        defaultHoldTimes[1] = 6 hours;
        defaultHoldTimes[2] = 24 hours;

        uint256[] memory defaultRiskPercentages = new uint256[](3);
        defaultRiskPercentages[0] = 5; // 5%
        defaultRiskPercentages[1] = 30; // 30%
        defaultRiskPercentages[2] = 60; // 60%

        _setRiskProfile(defaultHoldTimes, defaultRiskPercentages);
    }

    // --- Core Game Logic ---

    /**
     * @notice Tosses the potato to a new player, initiating the resolution phase.
     * @param _to The address of the player to receive the potato.
     */
    function tossPotato(address _to) external nonReentrant {
        require(currentState == GameState.Idle, "Potato: Not in Idle state.");
        require(
            ownerOf(POTATO_ID) == msg.sender,
            "Potato: Only holder can toss."
        );
        require(_to != address(0), "Potato: Cannot toss to zero address.");
        require(_to != msg.sender, "Potato: Cannot toss to self.");

        currentState = GameState.InFlight;
        gameInfo.tossBlockNumber = block.number;
        gameInfo.pendingReceiver = _to;

        emit PotatoTossed(msg.sender, _to, block.number);
    }

    /**
     * @notice Resolves a toss based on a future block hash, determining if the potato explodes or lands.
     * Can be called by anyone.
     */
    function resolveToss() external nonReentrant {
        require(
            currentState == GameState.InFlight,
            "Potato: No toss in flight."
        );
        require(
            block.number > gameInfo.tossBlockNumber + 1,
            "Potato: Resolution block not yet reached."
        );

        uint256 holdTime = block.timestamp - gameInfo.lastTransferTime;
        uint256 risk = _calculateRisk(holdTime);
        bool autoExplode = block.number >= gameInfo.tossBlockNumber + 256;

        // Get the future block hash for randomness.
        bytes32 futureBlockHash = blockhash(gameInfo.tossBlockNumber + 1);

        // Generate a pseudo-random number between 0 and 99.
        uint256 randomNumber = uint256(
            keccak256(abi.encodePacked(futureBlockHash, gameInfo.holder, gameInfo.pendingReceiver))
        ) % 100;

        if (autoExplode || randomNumber < risk) {
            // --- BOOM! Potato explodes. ---
            address oldHolder = gameInfo.holder;
            _burn(POTATO_ID);
            
            // Reset game state
            gameInfo.holder = address(0); // Game over
            currentState = GameState.Idle; // Or a new state e.g., GameOver

            emit PotatoExploded(oldHolder, holdTime);
        } else {
            // --- SAFE! Potato lands. ---
            address from = gameInfo.holder;
            address to = gameInfo.pendingReceiver;

            gameInfo.holder = to;
            gameInfo.lastTransferTime = block.timestamp;
            gameInfo.pendingReceiver = address(0);
            currentState = GameState.Idle;
            
            _safeTransfer(from, to, POTATO_ID, "");

            emit PotatoLanded(from, to, holdTime);
        }
    }

    // --- Helper Functions ---

    /**
     * @dev Calculates the explosion risk percentage based on how long the potato was held.
     * @param _holdTime The time in seconds the potato was held.
     * @return The risk percentage (0-100).
     */
    function _calculateRisk(uint256 _holdTime) internal view returns (uint256) {
        // Iterate backwards to find the correct risk tier.
        for (uint256 i = holdTimeTiers.length; i > 0; i--) {
            if (_holdTime >= holdTimeTiers[i - 1]) {
                return riskPercentageTiers[i - 1];
            }
        }
        // If hold time is less than the first tier, risk is 0.
        return 0;
    }

    // --- Admin Functions ---

    /**
     * @notice Allows the owner to update the risk profile of the game.
     * @param _holdTimeTiers Array of time thresholds in seconds.
     * @param _riskPercentageTiers Array of corresponding risk percentages.
     */
    function setRiskProfile(
        uint256[] memory _holdTimeTiers,
        uint256[] memory _riskPercentageTiers
    ) external onlyOwner {
        _setRiskProfile(_holdTimeTiers, _riskPercentageTiers);
    }

    function _setRiskProfile(
        uint256[] memory _holdTimeTiers,
        uint256[] memory _riskPercentageTiers
    ) internal {
        require(
            _holdTimeTiers.length == _riskPercentageTiers.length,
            "Potato: Array lengths must match."
        );
        for (uint256 i = 0; i < _riskPercentageTiers.length; i++) {
            require(
                _riskPercentageTiers[i] <= 100,
                "Potato: Risk cannot exceed 100."
            );
        }

        holdTimeTiers = _holdTimeTiers;
        riskPercentageTiers = _riskPercentageTiers;

        emit RiskProfileUpdated(_holdTimeTiers, _riskPercentageTiers);
    }
}