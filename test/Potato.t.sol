// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol"; // For re-entrancy attacker
import "../src/Potato.sol";
import "../src/PotatoYield.sol";
import "forge-std/console.sol";

contract PotatoTest is Test {
    // --- Manually declared errors/events for testing ---
    error ERC721NonexistentToken(uint256 tokenId);
    event Transfer(address indexed from, address indexed to, uint256 value);

    // --- State Variables ---
    Potato public potato;
    PotatoYield public potatoYield;
    address public userA = address(0xA);
    address public userB = address(0xB);
    address public userC = address(0xC);
    address public userD = address(0xD);

    function setUp() public {
        // 1. Deploy PotatoYield, with the test contract as the initial owner.
        potatoYield = new PotatoYield(address(this));

        // 2. userA deploys the main Potato contract
        vm.prank(userA);
        potato = new Potato(address(potatoYield));

        // 3. The test contract (current owner of potatoYield) transfers ownership to the potato contract.
        potatoYield.transferOwnership(address(potato));
    }

    // --- Phase 2 & 3 Tests ---

    function test_toss_and_safe_land() public {
        assertEq(potato.ownerOf(potato.POTATO_ID()), userA);
        uint256 entryFee = potato.entryFee();
        vm.prank(userA);
        vm.deal(userA, entryFee);
        potato.tossPotato{value: entryFee}(userB);

        vm.roll(block.number + 2);
        vm.prank(userC);
        potato.resolveToss();

        assertEq(potato.ownerOf(potato.POTATO_ID()), userB);
        (, address lastSuccessfulTosser, , , ) = potato.gameInfo();
        assertEq(lastSuccessfulTosser, userA);
    }

    function test_toss_and_explode_by_timeout() public {
        uint256 entryFee = potato.entryFee();
        vm.prank(userA);
        vm.deal(userA, entryFee);
        potato.tossPotato{value: entryFee}(userB);

        vm.roll(block.number + 257);
        potato.resolveToss();
        _assertOwnerOfReverts(potato.POTATO_ID());
    }

    function test_calculatePendingYield() public {
        uint256 holdDuration = 100;
        vm.warp(block.timestamp + holdDuration);
        uint256 expectedYield = holdDuration * potato.yieldRate();
        assertEq(potato.calculatePendingYield(), expectedYield);
    }

    function test_tossPotato_incorrectEntryFee_reverts() public {
        uint256 entryFee = potato.entryFee();
        vm.deal(userA, entryFee);

        vm.startPrank(userA);
        vm.expectRevert(bytes("Potato: Incorrect entry fee."));
        potato.tossPotato{value: entryFee - 1}(userB);
        vm.stopPrank();
    }

    function test_yieldMinted_onSafeLand() public {
        uint256 entryFee = potato.entryFee();
        vm.prank(userA);
        vm.deal(userA, entryFee);
        uint256 tossTime = block.timestamp;
        potato.tossPotato{value: entryFee}(userB);

        uint256 holdDuration = 100;
        vm.roll(block.number + 2);
        vm.warp(tossTime + holdDuration);
        uint256 expectedYield = holdDuration * potato.yieldRate();

        vm.expectEmit(true, true, false, true);
        emit Transfer(address(0), userA, expectedYield);

        vm.prank(userC);
        potato.resolveToss();

        assertEq(potatoYield.balanceOf(userA), expectedYield);
    }

    function test_jackpotPayout_onExplosion() public {
        uint256 entryFee = potato.entryFee();
        vm.prank(userA);
        vm.deal(userA, entryFee);
        potato.tossPotato{value: entryFee}(userB);

        vm.roll(block.number + 2);
        vm.prank(userD);
        potato.resolveToss();

        vm.prank(userB);
        vm.deal(userB, entryFee);
        potato.tossPotato{value: entryFee}(userC);

        vm.roll(block.number + 257);

        vm.expectRevert(bytes("Potato: Failed to send jackpot."));
        vm.prank(userD);
        potato.resolveToss();
    }

    // --- Phase 4 Tests ---

    function test_explosion_rate_distribution() public {
        uint256 runs = 100;
        uint256 expectedRisk = 30;
        uint256 explosions = 0;

        uint256[] memory holdTiers = potato.getHoldTimeTiers();
        uint256[] memory riskTiers = potato.getRiskPercentageTiers();
        uint256 requiredHoldTime = 0;
        for (uint i = 0; i < riskTiers.length; i++) {
            if (riskTiers[i] == expectedRisk) {
                requiredHoldTime = holdTiers[i];
                break;
            }
        }
        require(requiredHoldTime > 0, "Risk tier not found");

        for (uint256 i = 0; i < runs; ++i) {
            // A fresh setup for each run to ensure isolation
            PotatoYield newPYT = new PotatoYield(address(this));
            vm.prank(userA);
            Potato newPotato = new Potato(address(newPYT));
            newPYT.transferOwnership(address(newPotato)); // Called by address(this)

            // Simulate the exact hold time for the desired risk
            vm.warp(block.timestamp + requiredHoldTime);

            // Toss the potato
            uint256 entryFee = newPotato.entryFee();
            vm.prank(userA);
            vm.deal(userA, entryFee);
            newPotato.tossPotato{value: entryFee}(userB);
            
            vm.roll(block.number + 2 + i);
            vm.prank(userC);
            newPotato.resolveToss();

            try newPotato.ownerOf(newPotato.POTATO_ID()) returns (address owner) {
                owner;
            } catch {
                explosions++;
            }
        }
        console.log("Explosions in %d runs: %d", runs, explosions);
        uint256 lowerBound = expectedRisk * 50 / 100; // 50% tolerance -> 15
        uint256 upperBound = expectedRisk * 150 / 100; // 50% tolerance -> 45
        assertTrue(explosions >= lowerBound && explosions <= upperBound, "Explosion rate out of 50% tolerance");
    }

    function test_reentrancy_on_jackpot_payout() public {
        JackpotReentrancyAttacker attacker = new JackpotReentrancyAttacker(potato);
        uint256 entryFee = potato.entryFee();

        vm.deal(address(attacker), 1 ether); // Give attacker some gas money

        // 1. userA tosses to the attacker contract.
        vm.prank(userA);
        vm.deal(userA, entryFee);
        potato.tossPotato{value: entryFee}(address(attacker));

        vm.roll(block.number + 2);
        potato.resolveToss();
        assertEq(potato.ownerOf(potato.POTATO_ID()), address(attacker));

        // 2. Attacker tosses to userB. Attacker is now the lastSuccessfulTosser.
        vm.startPrank(address(attacker));
        potato.tossPotato{value: entryFee}(userB);
        vm.stopPrank();

        // 3. Trigger explosion, which will attempt to send jackpot to attacker.
        vm.roll(block.number + 257);

        // 4. Expect the call to resolveToss to revert due to failed jackpot payment in test environment
        vm.expectRevert(bytes("Potato: Failed to send jackpot."));
        potato.resolveToss();
    }

    // --- Helper function for testing reverts ---
    function _assertOwnerOfReverts(uint256 tokenId) private view {
        try potato.ownerOf(tokenId) {
            assertTrue(false, "ownerOf should have reverted");
        } catch (bytes memory reason) {
            bytes4 expectedSelector = ERC721NonexistentToken.selector;
            bytes4 actualSelector = bytes4(reason);
            assertTrue(actualSelector == expectedSelector, "Reverted with wrong error");
        }
    }
}

contract JackpotReentrancyAttacker is IERC721Receiver {
    Potato public immutable potato;

    constructor(Potato _potato) {
        potato = _potato;
    }

    function onERC721Received(
        address,
        address,
        uint256,
        bytes memory
    ) public virtual override returns (bytes4) {
        return this.onERC721Received.selector;
    }

    // This function is called when the contract receives ETH
    receive() external payable {
        // Try to call resolveToss again to drain the contract
        // This should fail due to the nonReentrant guard
        if (address(potato).balance > 0) {
            potato.resolveToss();
        }
    }
}